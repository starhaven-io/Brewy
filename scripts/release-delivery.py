#!/usr/bin/env python3
"""Validate release metadata and resume delivery without replacing release assets."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value), "Expected a numeric release version")
    return tuple(map(int, value.split(".")))


def build_number(value):
    require(re.fullmatch(r"[1-9][0-9]*", value), "Expected a positive integer build number")
    return int(value)


def feed(path):
    items = ET.parse(path).getroot().findall("./channel/item")
    require(len(items) == 1, "Expected one release in the appcast")
    item = items[0]
    tag = item.findtext(f"{SPARKLE}shortVersionString", "")
    build = item.findtext(f"{SPARKLE}version", "")
    version(tag)
    build_number(build)
    return tag, build, item.find("enclosure")


def check_version(tag, build, current):
    current_tag, current_build, _ = feed(current)
    require(version(tag) > version(current_tag), "Release version must increase")
    require(build_number(build) > build_number(current_build), "Build number must increase")


def check_feed(incoming, current):
    if incoming.read_bytes() == current.read_bytes():
        return
    tag, build, _ = feed(incoming)
    check_version(tag, build, current)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_metadata():
    metadata = {key: os.environ[name] for key, name in {
        "repository": "GITHUB_REPOSITORY", "commit": "GITHUB_SHA",
        "tag": "TAG", "build": "BUILD_NUMBER",
    }.items()}
    version(metadata["tag"])
    build_number(metadata["build"])
    require(re.fullmatch(r"[0-9a-f]{40}", metadata["commit"]), "Invalid source commit")
    metadata["asset"] = f"Brewy-{metadata['tag']}.zip"
    return metadata


def validate_manifest(directory, metadata):
    expected = expected_metadata()
    require(all(metadata.get(key) == value for key, value in expected.items()),
            "Delivery metadata does not match this workflow's source and version")
    require(re.fullmatch(r"[0-9a-f]{64}", metadata.get("sha256", "")), "Invalid asset digest")
    require(type(metadata.get("release_id")) is int and metadata["release_id"] > 0, "Invalid release ID")
    appcast = directory / "appcast.xml"
    require(sha256(appcast) == metadata["appcast_sha256"], "Appcast digest changed")
    tag, build, enclosure = feed(appcast)
    require((tag, build) == (metadata["tag"], metadata["build"]), "Appcast version mismatch")
    require(enclosure is not None, "Missing appcast enclosure")
    url = f"https://github.com/{metadata['repository']}/releases/download/{tag}/{metadata['asset']}"
    require(enclosure.get("url") == url, "Appcast download URL mismatch")
    require(enclosure.get("length") == str(metadata["length"]) and metadata["length"] > 0,
            "Appcast length mismatch")
    require(bool(enclosure.get(f"{SPARKLE}edSignature")), "Missing Sparkle signature")


def prepare(directory):
    metadata = expected_metadata()
    metadata.update(sha256=os.environ["ARTIFACT_SHA256"], length=int(os.environ["SPARKLE_LENGTH"]),
                    release_id=int(os.environ["RELEASE_ID"]),
                    appcast_sha256=sha256(directory / "appcast.xml"))
    validate_manifest(directory, metadata)
    (directory / "delivery.json").write_text(json.dumps(metadata) + "\n")


def gh(*arguments, token=None, output=None):
    environment = os.environ if token is None else {**os.environ, "GH_TOKEN": token}
    return subprocess.run(["gh", *arguments], env=environment, check=True,
                          stdout=output or subprocess.PIPE, stderr=subprocess.PIPE,
                          text=output is None).stdout


def tag_commit(repository, tag):
    result = subprocess.run(["gh", "api", "--include", f"repos/{repository}/git/ref/tags/{tag}"],
                            capture_output=True, text=True)
    # Only a confirmed 404 means no tag. Authorization, network and server errors stop publication.
    status = re.match(r"HTTP/\S+ (\d{3})\b", result.stdout)
    require(status is not None, "Could not determine release tag status")
    if status[1] == "404":
        return None
    require(status[1] == "200" and result.returncode == 0, "Could not read release tag")
    return json.loads(gh("api", f"repos/{repository}/commits/{tag}"))["sha"]


def release_state(metadata, *, allow_draft, token=None):
    repository, tag = metadata["repository"], metadata["tag"]
    release = json.loads(gh("api", f"repos/{repository}/releases/{metadata['release_id']}", token=token))
    require(release["id"] == metadata["release_id"], "Release identity changed")
    require(release["tag_name"] == tag and release["target_commitish"] == metadata["commit"],
            "Release targets a different source commit")
    require(not release["prerelease"], "Refusing to distribute a prerelease")
    require(allow_draft or not release["draft"], "Release is not published")
    commit = tag_commit(repository, tag)
    require((release["draft"] and commit is None) or
            (not release["draft"] and commit == metadata["commit"]), "Release tag binding changed")
    assets = [asset for asset in release["assets"] if asset["name"] == metadata["asset"]]
    require(len(assets) == 1 and assets[0]["size"] == metadata["length"] and
            assets[0]["digest"] == f"sha256:{metadata['sha256']}", "Release asset mismatch")
    require(type(assets[0].get("id")) is int and assets[0]["id"] > 0, "Invalid release asset ID")
    return release, assets[0]


def verify(directory, *, publish=False):
    metadata = json.loads((directory / "delivery.json").read_text())
    validate_manifest(directory, metadata)
    release_token = os.environ["GH_PUBLISH_TOKEN"] if publish else None
    _, hosted_asset = release_state(metadata, allow_draft=publish, token=release_token)
    repository = metadata["repository"]
    with tempfile.TemporaryDirectory() as temporary:
        asset = Path(temporary) / metadata["asset"]
        with asset.open("wb") as output:
            gh("api", f"repos/{repository}/releases/assets/{hosted_asset['id']}",
               "--header", "Accept: application/octet-stream", token=release_token, output=output)
        require(asset.stat().st_size == metadata["length"] and sha256(asset) == metadata["sha256"],
                "Release bytes differ from the prepared, signed archive")
        gh("attestation", "verify", str(asset), "--repo", repository,
           "--signer-workflow", f"{repository}/.github/workflows/release.yml",
           "--source-digest", metadata["commit"], "--source-ref", "refs/heads/main",
           "--deny-self-hosted-runners")
    release, current_asset = release_state(metadata, allow_draft=publish, token=release_token)
    require(current_asset["id"] == hosted_asset["id"], "Release asset identity changed during verification")
    if publish and release["draft"]:
        gh("api", f"repos/{repository}/releases/{metadata['release_id']}", "--method", "PATCH", "-F", "draft=false",
           token=release_token)
    release_state(metadata, allow_draft=False, token=release_token)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "verify", "publish"):
        commands.add_parser(name).add_argument("directory", type=Path)
    check = commands.add_parser("check-version")
    check.add_argument("tag")
    check.add_argument("build")
    check.add_argument("current", type=Path)
    check = commands.add_parser("check-feed")
    check.add_argument("incoming", type=Path)
    check.add_argument("current", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.directory)
    elif args.command in ("verify", "publish"):
        verify(args.directory, publish=args.command == "publish")
    elif args.command == "check-version":
        check_version(args.tag, args.build, args.current)
    else:
        check_feed(args.incoming, args.current)


if __name__ == "__main__":
    main()
