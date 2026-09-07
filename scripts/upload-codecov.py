#!/usr/bin/env python3
"""Upload explicit same-run reports with the fleet-pinned Codecov CLI and OIDC."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


# Update this pair in fleet canon, review the upstream release and checksum,
# then deliver it through a fleet release and consumer sync.
CLI_VERSION = "v11.3.1"
CLI_SHA256 = "ca1d64196d2d34771084afe76ea657d581bf628e31d993ff8e52ea09cc88a56d"
CLI_URL = f"https://cli.codecov.io/{CLI_VERSION}/linux/codecov"
OIDC_AUDIENCE = "https://codecov.io"


class UploadError(Exception):
    """A failed precondition or upload; never falls back to unauthenticated use."""


def plain(value, label):
    if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise UploadError(f"{label} must be a nonempty single-line string")
    return value


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise UploadError("event commit must be a full lowercase Git SHA")
    return value


def event_identity(env):
    repository = plain(env.get("GITHUB_REPOSITORY"), "GITHUB_REPOSITORY")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise UploadError("GITHUB_REPOSITORY must be an owner/repository slug")
    event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text())
    if event.get("repository", {}).get("full_name") != repository:
        raise UploadError("event repository does not match GITHUB_REPOSITORY")
    run_id = plain(env.get("GITHUB_RUN_ID"), "GITHUB_RUN_ID")
    if not run_id.isdecimal():
        raise UploadError("GITHUB_RUN_ID must be numeric")
    arguments = ["--slug", repository, "--git-service", "github", "--build-code", run_id,
                 "--build-url", f"https://github.com/{repository}/actions/runs/{run_id}"]
    event_name = env.get("GITHUB_EVENT_NAME")
    if event_name == "pull_request":
        pr = event["pull_request"]
        if pr["head"]["repo"]["full_name"] != repository:
            raise UploadError("fork pull requests do not use the authenticated uploader")
        number = event["number"]
        if type(number) is not int or number < 1:
            raise UploadError("pull request number must be a positive integer")
        if env.get("GITHUB_REF") != f"refs/pull/{number}/merge":
            raise UploadError("pull request ref does not match the event")
        commit = sha(pr["head"]["sha"])
        branch = plain(pr["head"]["ref"], "pull request branch")
        arguments += ["--pr", str(number)]
    elif event_name == "push":
        commit = sha(env.get("GITHUB_SHA"))
        ref = plain(env.get("GITHUB_REF"), "GITHUB_REF")
        if event.get("after") != commit or event.get("ref") != ref or not ref.startswith("refs/heads/"):
            raise UploadError("push commit or branch does not match the event")
        branch = plain(ref.removeprefix("refs/heads/"), "push branch")
    else:
        raise UploadError("only push and same-repository pull_request events are supported")
    return arguments + ["--commit-sha", commit, "--branch", branch]


def report_paths(values):
    root = Path.cwd().resolve()
    paths = []
    for value in values:
        candidate = Path(value)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise UploadError("report paths must be relative to the workspace")
        current = root
        for component in candidate.parts:
            current /= component
            if current.is_symlink():
                raise UploadError(f"report path must not contain a symlink: {value}")
        if not current.is_file() or current.stat().st_size == 0:
            raise UploadError(f"report is missing, empty, or not a regular file: {value}")
        paths.append(str(current))
    return paths


def source_path(value, workspace, source_root=None, require_relative=False):
    plain(value, "coverage source path")
    path = PurePosixPath(value)
    if ".." in path.parts or "\\" in value:
        raise UploadError("coverage source paths must not contain traversal or backslashes")
    if require_relative and path.is_absolute():
        raise UploadError("coverage still contains absolute source paths; run --prepare in the producer")
    absolute = path if path.is_absolute() else (source_root or workspace) / path
    try:
        return absolute.relative_to(workspace).as_posix()
    except ValueError as error:
        raise UploadError("coverage contains an absolute source path outside GITHUB_WORKSPACE") from error


def normalized_report(content, workspace, require_relative=False):
    if content.lstrip().startswith("<"):
        root = ET.fromstring(content)
        if root.tag != "coverage":
            raise UploadError("XML coverage reports must use the Cobertura coverage root")
        sources = root.findall("./sources/source")
        origins = {source_path(source.text or ".", workspace, require_relative=require_relative) for source in sources}
        if len(origins) > 1:
            raise UploadError("Cobertura reports must have one unambiguous source root")
        if require_relative and origins - {"."}:
            raise UploadError("Cobertura source root must be normalized with --prepare in the producer")
        source_root = workspace / next(iter(origins), ".")
        for source in sources:
            source.text = "."
        classes = root.findall(".//class")
        if not classes:
            raise UploadError("Cobertura report contains no classes")
        for entry in classes:
            entry.set("filename", source_path(entry.get("filename"), workspace, source_root, require_relative))
        return ET.tostring(root, encoding="unicode") + "\n"
    lines = content.splitlines(keepends=True)
    found = False
    for index, line in enumerate(lines):
        if line.startswith("SF:"):
            found = True
            ending = "\n" if line.endswith("\n") else ""
            lines[index] = "SF:" + source_path(line[3:].rstrip("\r\n"), workspace,
                                             require_relative=require_relative) + ending
    if not found:
        raise UploadError("coverage report must contain LCOV source entries or Cobertura XML")
    return "".join(lines)


def prepare_reports(args, env):
    workspace = PurePosixPath(plain(env.get("GITHUB_WORKSPACE"), "GITHUB_WORKSPACE"))
    if not workspace.is_absolute() or ".." in workspace.parts:
        raise UploadError("GITHUB_WORKSPACE must be an absolute source root")
    paths = report_paths(args.coverage)
    report_paths(args.junit)
    # Validate every report before replacing any producer output.
    prepared = [(Path(path), normalized_report(Path(path).read_text(), workspace)) for path in paths]
    for path, content in prepared:
        path.write_text(content)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise UploadError("upload bootstrap endpoint unexpectedly redirected")


def open_https(request):
    return urllib.request.build_opener(NoRedirect()).open(request, timeout=60)


def oidc_request(env):
    token = plain(env.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN"), "ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    url = urllib.parse.urlsplit(plain(env.get("ACTIONS_ID_TOKEN_REQUEST_URL"), "ACTIONS_ID_TOKEN_REQUEST_URL"))
    if (url.scheme != "https" or not url.hostname or
            not url.hostname.endswith(".actions.githubusercontent.com") or
            url.username or url.password or url.port not in (None, 443) or url.fragment):
        raise UploadError("OIDC request URL must be a GitHub Actions HTTPS endpoint")
    query = [(key, value) for key, value in urllib.parse.parse_qsl(url.query) if key != "audience"]
    query.append(("audience", OIDC_AUDIENCE))
    return urllib.request.Request(
        urllib.parse.urlunsplit(url._replace(query=urllib.parse.urlencode(query))),
        headers={"Authorization": f"Bearer {token}"},
    )


def download_cli(path):
    with open_https(CLI_URL) as response, path.open("wb") as target:
        shutil.copyfileobj(response, target)
    if hashlib.sha256(path.read_bytes()).hexdigest() != CLI_SHA256:
        raise UploadError("downloaded Codecov CLI does not match the reviewed SHA-256")
    path.chmod(0o700)


def upload(args, env):
    identity = event_identity(env)
    reports = [("coverage", report_paths(args.coverage)), ("test_results", report_paths(args.junit))]
    for path in reports[0][1]:
        normalized_report(Path(path).read_text(), PurePosixPath("/"), require_relative=True)
    request = oidc_request(env)
    with tempfile.TemporaryDirectory(prefix="fleet-codecov-") as directory:
        work = Path(directory)
        binary = work / "codecov"
        download_cli(binary)
        with open_https(request) as response:
            token = plain(json.load(response).get("value"), "OIDC response token")
        print(f"::add-mask::{token}", flush=True)
        config = work / "codecov.yml"
        config.write_text("{}\n")
        network = work / "network"
        network.mkdir()
        # Do not expose the OIDC minting credential or unrelated job environment
        # to the downloaded process. It only receives its short-lived upload token.
        child_env = {
            "PATH": env.get("PATH", "/usr/bin:/bin"),
            "HOME": str(work),
            "LANG": "C.UTF-8",
            "GITHUB_ACTIONS": "true",
            "CODECOV_TOKEN": token,
        }
        for report_type, paths in reports:
            if not paths:
                continue
            command = [str(binary), "--disable-telem", "--codecov-yml-path", str(config),
                       "upload-process", "--fail-on-error", "--disable-search", "--disable-file-fixes",
                       "--plugin", "noop", "--network-root-folder", str(network),
                       "--report-type", report_type, *identity]
            for path in paths:
                command += ["--file", path]
            result = subprocess.run(command, env=child_env, cwd=work, check=False)
            if result.returncode:
                raise UploadError(f"Codecov {report_type} upload failed (exit {result.returncode})")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true", help="normalize producer report paths without network or credentials")
    parser.add_argument("--coverage", action="append", default=[], help="workspace-relative coverage report; repeatable")
    parser.add_argument("--junit", action="append", default=[], help="workspace-relative JUnit report; repeatable")
    args = parser.parse_args(argv)
    if not args.coverage and not args.junit:
        parser.error("at least one --coverage or --junit report is required")
    try:
        if args.prepare:
            prepare_reports(args, os.environ)
        else:
            upload(args, os.environ)
    except UploadError as error:
        print(f"Codecov upload failed: {error}", file=sys.stderr)
        return 1
    except (OSError, KeyError, TypeError, ValueError, ET.ParseError, urllib.error.URLError):
        # Network exceptions may contain endpoint query credentials; keep the
        # diagnostic independent of exception text and retain a failing exit.
        print("Codecov upload failed: check event identity, report files, OIDC grant, CLI integrity, and uploader output.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
