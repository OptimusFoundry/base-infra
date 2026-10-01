"""Static checks of .github/workflows/pmbot-terraform.yml (polymarket-bot CH-008-T6). Stdlib only:

    python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v    # from the repo root
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[3] / ".github" / "workflows" / "pmbot-terraform.yml"
PINS = {
    "actions/checkout": "11d5960a326750d5838078e36cf38b85af677262",                      # v4
    "hashicorp/setup-terraform": "b9cd54a3c349d3f38e8881555d616ced269862dd",             # v3
    "aws-actions/configure-aws-credentials": "7474bc4690e29a8392af63c5b98e7449536d5c3a",  # v4
}
STACK_PATHS = ['"products/pmbot/**"', '".github/workflows/pmbot-terraform.yml"']


def code() -> str:
    """The workflow without whole-line comments."""
    return "\n".join(ln for ln in WORKFLOW.read_text(encoding="utf-8").splitlines()
                     if not ln.strip().startswith("#"))


def job(name: str) -> str:
    """The text of one job: from `  <name>:` to the next two-space-indented key or the end."""
    match = re.search(rf"^  {name}:\n(.*?)(?=^  \S|\Z)", code(), re.M | re.S)
    assert match is not None, name
    return match.group(1)


def permissions(text: str, indent: int) -> dict[str, str]:
    """The `permissions:` mapping at `indent` spaces (0 = workflow level, 4 = inside a job)."""
    pad = " " * indent
    match = re.search(rf"^{pad}permissions:\n((?:{pad}  [\w-]+: \w+\n)+)", text, re.M)
    assert match is not None, f"no permissions block at indent {indent}"
    return dict(line.strip().split(": ", 1) for line in match.group(1).splitlines())


class Triggers(unittest.TestCase):
    def test_only_products_pmbot_and_this_workflow_trigger_it(self) -> None:
        text = code()
        self.assertIn("pull_request:", text)
        self.assertIn("branches: [main]", text)
        paths = re.findall(r'^\s+- (".*")$', text, re.M)
        self.assertTrue(paths)
        self.assertEqual(sorted(set(paths)), sorted(STACK_PATHS))
        self.assertEqual(paths.count('"products/pmbot/**"'), 2)

    def test_every_run_step_works_inside_products_pmbot_only(self) -> None:
        text = code()
        self.assertIn("working-directory: products/pmbot", text)
        self.assertNotIn("-chdir", text)
        self.assertNotIn("platform", text.replace("platform-alerts", ""))
        self.assertIn("terraform fmt -check -recursive", text)


class Auth(unittest.TestCase):
    def test_oidc_roles_per_job_and_no_secrets(self) -> None:
        self.assertNotIn("secrets.", code())
        self.assertIn("role-to-assume: ${{ vars.PMBOT_TF_PLAN_ROLE_ARN }}", job("plan"))
        self.assertNotIn("PMBOT_TF_APPLY_ROLE_ARN", job("plan"))
        self.assertIn("role-to-assume: ${{ vars.PMBOT_TF_APPLY_ROLE_ARN }}", job("apply"))
        self.assertNotIn("PMBOT_TF_PLAN_ROLE_ARN", job("apply"))
        for name in ("plan", "apply"):
            self.assertIn("id-token: write", job(name))
            self.assertIn("aws-region: ${{ vars.AWS_REGION }}", job(name))
        self.assertIn("pull-requests: write", job("plan"))
        self.assertNotIn("pull-requests: write", job("apply"))
        self.assertIn("GH_TOKEN: ${{ github.token }}", job("plan"))

    def test_permissions_are_exactly_these_per_job(self) -> None:
        self.assertEqual(permissions(code(), 0), {"contents": "read"})
        self.assertEqual(permissions(job("plan"), 4),
                         {"contents": "read", "id-token": "write", "pull-requests": "write"})
        self.assertEqual(permissions(job("apply"), 4), {"contents": "read", "id-token": "write"})

    def test_every_action_is_pinned_to_a_full_commit_sha(self) -> None:
        uses = re.findall(r"uses:\s*(\S+)", code())
        self.assertTrue(uses)
        self.assertEqual(sorted(set(uses)), sorted(f"{a}@{sha}" for a, sha in PINS.items()))


class Jobs(unittest.TestCase):
    def test_pr_job_plans_read_only_and_never_applies(self) -> None:
        plan = job("plan")
        self.assertIn("if: github.event_name == 'pull_request'", plan)
        self.assertIn("-lock=false", plan)
        self.assertNotIn("terraform apply", plan)
        self.assertIn("gh pr comment", plan)
        self.assertIn("python3 ci/plan_guard.py plan.json", plan)

    def test_apply_job_runs_on_main_pushes_and_applies_only_the_guarded_saved_plan(self) -> None:
        """Mutation-checked: moving the guard after the apply, or applying without `tfplan`, fails."""
        apply = job("apply")
        self.assertIn("if: github.event_name == 'push' && github.ref == 'refs/heads/main'", apply)
        order = [apply.index(s) for s in (
            "python3 -m unittest discover",
            "terraform fmt -check -recursive",
            "terraform validate",
            "terraform plan -input=false -no-color -detailed-exitcode -out=tfplan",
            "python3 ci/plan_guard.py plan.json",
            "terraform apply -input=false -no-color tfplan",
        )]
        self.assertEqual(order, sorted(order))
        applies = re.findall(r"terraform apply[^\n]*", apply)
        self.assertEqual(applies, ["terraform apply -input=false -no-color tfplan"])
        self.assertEqual(apply.count("if: steps.plan.outputs.exitcode == '2'"), 2)

    def test_guard_unit_tests_run_before_terraform_in_both_jobs(self) -> None:
        for name in ("plan", "apply"):
            text = job(name)
            self.assertLess(text.index("python3 -m unittest discover"), text.index("hashicorp/setup-terraform"))

    def test_runs_are_serialised_and_plan_files_are_removed(self) -> None:
        text = code()
        self.assertIn("cancel-in-progress: false", text)
        self.assertEqual(text.count("rm -f tfplan plan.json"), 2)

    def test_exit_codes_are_captured_under_bash_e(self) -> None:
        """GitHub runs `bash -e`: a bare failing command ends the step before its diagnostics print.
        Mutation-checked: split the guard line into a bare command plus `code=$?` and this fails."""
        self.assertIn("code=0; python3 ci/plan_guard.py plan.json > guard.md || code=$?", job("apply"))
        for name, expected in (("plan", 2), ("apply", 1)):
            blocks = re.findall(r"set \+e\n(.*?)\n\s*set -e\n", job(name), re.S)
            self.assertEqual(len(blocks), expected, name)
            for block in blocks:
                self.assertIn("code=$?", block)

    def test_terraform_wrapper_is_off_so_exit_codes_are_terraforms(self) -> None:
        for name in ("plan", "apply"):
            self.assertIn("terraform_wrapper: false", job(name))


if __name__ == "__main__":
    unittest.main()
