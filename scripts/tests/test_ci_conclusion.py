import os
from pathlib import Path
import re
import subprocess
import textwrap
import unittest


WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "ci.yml"


def workflow_run_block(step_name: str) -> str:
    source = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        rf"^      - name: {re.escape(step_name)}\n(?:^        .*\n)*?^        run: \|\n(?P<run>(?:^          .*\n|^\n)+)",
        source,
        re.MULTILINE,
    )
    if match is None:
        raise AssertionError(f"missing workflow step: {step_name}")
    return textwrap.dedent(match.group("run"))


class CIConclusionTests(unittest.TestCase):
    def setUp(self):
        self.script = workflow_run_block("Result")
        self.environment = {
            "GITHUB_EVENT_NAME": "pull_request",
            "GENERATOR_RESULT": "success",
            "COMMITS_RESULT": "success",
            "CHECK_RESULT": "success",
            "CODEQL_RESULT": "success",
            "ZIZMOR_RESULT": "success",
            "PINPRICK_RESULT": "success",
            "CODECOV_RESULT": "success",
            "MATRIX": '[{"check":"test"}]',
            "RUN_CODEQL": "true",
            "RUN_ZIZMOR": "true",
            "RUN_CODECOV": "true",
            "CODECOV_ELIGIBLE": "true",
            "EVENT_NAME": "pull_request",
        }

    def conclude(self, **overrides):
        return subprocess.run(
            ["/bin/bash", "-euo", "pipefail", "-c", self.script],
            env={**os.environ, **self.environment, **overrides},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_required_audit_results_fail_closed(self):
        self.assertEqual(self.conclude().returncode, 0)
        for result in ("failure", "cancelled", "skipped", ""):
            with self.subTest(result=result):
                self.assertNotEqual(self.conclude(PINPRICK_RESULT=result).returncode, 0)

    def test_only_unselected_workflow_audits_may_skip(self):
        self.assertEqual(
            self.conclude(RUN_ZIZMOR="false", ZIZMOR_RESULT="skipped", PINPRICK_RESULT="skipped").returncode,
            0,
        )
        self.assertNotEqual(
            self.conclude(RUN_ZIZMOR="false", ZIZMOR_RESULT="skipped", PINPRICK_RESULT="failure").returncode,
            0,
        )
        self.assertNotEqual(
            self.conclude(RUN_ZIZMOR="", ZIZMOR_RESULT="skipped", PINPRICK_RESULT="skipped").returncode,
            0,
        )

    def test_every_routing_decision_fails_closed(self):
        self.assertNotEqual(self.conclude(EVENT_NAME="unknown", COMMITS_RESULT="skipped").returncode, 0)
        self.assertNotEqual(self.conclude(MATRIX="", CHECK_RESULT="skipped").returncode, 0)
        self.assertNotEqual(self.conclude(RUN_CODEQL="", CODEQL_RESULT="skipped").returncode, 0)
        self.assertNotEqual(self.conclude(RUN_CODECOV="", CODECOV_RESULT="skipped").returncode, 0)
        self.assertNotEqual(self.conclude(CODECOV_ELIGIBLE="", CODECOV_RESULT="skipped").returncode, 0)


if __name__ == "__main__":
    unittest.main()
