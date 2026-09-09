import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"


def workflow_run_block(workflow, step_name, *, strip_comments=True):
    step_marker = f"      - name: {step_name}\n"
    step_start = workflow.index(step_marker) + len(step_marker)
    next_step = re.search(r"^      - ", workflow[step_start:], re.MULTILINE)
    step_end = step_start + next_step.start() if next_step else len(workflow)
    step = workflow[step_start:step_end]
    run_marker = "        run: |\n"
    run_start = step.index(run_marker) + len(run_marker)
    run_lines = step[run_start:].splitlines()
    return "\n".join(
        line[10:] if line.startswith("          ") else line
        for line in run_lines
        if not strip_comments or not line.lstrip().startswith("#")
    )




class CaskDCOTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.tap = self.root / "tap checkout"
        self.runner = self.root / "runner temp"
        self.bin = self.root / "bin"
        for directory in (self.tap, self.runner, self.bin):
            directory.mkdir()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update({
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Fixture Author",
            "GIT_AUTHOR_EMAIL": "author@example.test",
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "RUNNER_TEMP": str(self.runner),
            "TAP_ROOT": str(self.tap),
            "APP_SLUG": "fixture-bot",
            "VERSION": "1.2.3",
        })
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture Committer")
        self.git("config", "user.email", "committer@example.test")
        self.git("config", "core.hooksPath", ".githooks")
        self.hooks = self.tap / ".githooks"
        self.hooks.mkdir()
        self.write_executable(self.hooks / "commit-msg", (ROOT / ".githooks/commit-msg").read_text())
        self.write_executable(self.hooks / "pre-push", "#!/bin/sh\nexit 1\n")
        self.write_executable(self.bin / "gh", '#!/bin/sh\nif [ "$1" = api ]; then printf "42\\n"; fi\n')
        self.write_executable(self.bin / "brew", '''#!/bin/sh
set -eu
case "$1" in
  --repo) printf '%s\n' "$TAP_ROOT" ;;
  tap|trust) ;;
  bump-cask-pr)
    if [ "${REPLACE_HOOK:-0}" = 1 ]; then
      rm "$TAP_ROOT/.githooks/prepare-commit-msg"
      ln -s "$TAP_ROOT/keep-this-link" "$TAP_ROOT/.githooks/prepare-commit-msg"
      exit 9
    fi
    [ "${FAIL_BREW:-0}" = 0 ] || exit 9
    printf 'update\n' >> "$TAP_ROOT/cask.rb"
    git -C "$TAP_ROOT" add cask.rb
    message='brewy 1.2.3'
    if [ "${EXISTING_SIGNOFF:-0}" = 1 ]; then
      message="$(printf '%s\n\nSigned-off-by: Fixture Author <author@example.test>\n' "$message")"
    fi
    git -C "$TAP_ROOT" -c commit.gpgSign=false commit --no-edit --verbose --message="$message" -- cask.rb
    ;;
  *) exit 8 ;;
esac
''')
        self.script = workflow_run_block(
            RELEASE_WORKFLOW.read_text(), "Bump Homebrew cask", strip_comments=False
        )

    @staticmethod
    def write_executable(path, contents):
        path.write_text(contents)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.tap), *args], env=self.env, text=True).strip()

    def run_bump(self):
        return subprocess.run(
            ["/bin/bash", "-eu", "-o", "pipefail", "-c", self.script],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=20,
        )

    def assert_cleaned(self):
        self.assertFalse((self.hooks / "prepare-commit-msg").is_symlink())
        self.assertEqual(list(self.runner.iterdir()), [])
        self.assertEqual(self.git("config", "--local", "core.hooksPath"), ".githooks")

    def test_actual_author_is_signed_once_and_existing_hooks_are_preserved(self):
        original = (self.hooks / "commit-msg").read_bytes()
        for duplicate in ("0", "1"):
            self.env["EXISTING_SIGNOFF"] = duplicate
            result = self.run_bump()
            self.assertEqual(result.returncode, 0, result.stderr)
            message = self.git("log", "-1", "--format=%B")
            author = self.git("log", "-1", "--format=%an <%ae>")
            self.assertEqual(message.splitlines()[0], "brewy 1.2.3")
            self.assertEqual(message.count("Signed-off-by:"), 1)
            self.assertIn("Signed-off-by: " + author, message)
            self.assertNotEqual(author, self.git("log", "-1", "--format=%cn <%ce>"))
            self.assertEqual((self.hooks / "commit-msg").read_bytes(), original)
            self.assertEqual((self.hooks / "pre-push").read_text(), "#!/bin/sh\nexit 1\n")
            self.assert_cleaned()

    def test_existing_validator_still_blocks_commit(self):
        self.write_executable(self.hooks / "commit-msg", "#!/bin/sh\nexit 1\n")
        self.assertNotEqual(self.run_bump().returncode, 0)
        self.assert_cleaned()

    def test_failure_cleans_hook_for_retry(self):
        self.env["FAIL_BREW"] = "1"
        self.assertEqual(self.run_bump().returncode, 9)
        self.assert_cleaned()
        self.env["FAIL_BREW"] = "0"
        self.assertEqual(self.run_bump().returncode, 0)
        self.assert_cleaned()

    def test_existing_prepare_hook_is_preserved(self):
        prepare = self.hooks / "prepare-commit-msg"
        self.write_executable(prepare, "#!/bin/sh\nexit 0\n")
        before = prepare.read_bytes()
        result = self.run_bump()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing prepare-commit-msg", result.stdout)
        self.assertEqual(prepare.read_bytes(), before)
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_external_hook_directory_is_not_modified(self):
        external = self.root / "outside hooks"
        external.mkdir()
        link = self.tap / "outside-link"
        link.symlink_to(external, target_is_directory=True)
        for location in (external, link):
            self.git("config", "core.hooksPath", str(location))
            result = self.run_bump()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside the fresh checkout", result.stdout)
            self.assertEqual(list(external.iterdir()), [])
            self.assertEqual(list(self.runner.iterdir()), [])

    def test_inherited_global_hook_directory_is_not_modified(self):
        external = self.root / "global hooks"
        external.mkdir()
        global_config = self.root / "gitconfig"
        self.env["GIT_CONFIG_GLOBAL"] = str(global_config)
        self.git("config", "--global", "core.hooksPath", str(external))
        self.git("config", "--local", "--unset", "core.hooksPath")
        before = global_config.read_bytes()
        self.assertNotEqual(self.run_bump().returncode, 0)
        self.assertEqual(global_config.read_bytes(), before)
        self.assertEqual(list(external.iterdir()), [])
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_cleanup_preserves_a_substituted_link(self):
        self.env["REPLACE_HOOK"] = "1"
        self.assertEqual(self.run_bump().returncode, 9)
        self.assertEqual(os.readlink(self.hooks / "prepare-commit-msg"), str(self.tap / "keep-this-link"))
        self.assertEqual(list(self.runner.iterdir()), [])
