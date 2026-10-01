"""Tests for plan_guard.py (polymarket-bot CH-008-T4). Stdlib unittest, no Terraform, no AWS:

    python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v    # from the repo root
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import plan_guard  # noqa: E402

PAPER_ENV = [{"name": "LIVE_TRADING", "value": "0"}, {"name": "LIVE_LEAGUES", "value": "NBA,NHL"},
             {"name": "SPORTS_S3", "value": "ro"}]


def rc(address: str, actions: list[str], *, after: Any = None, after_unknown: Any = None,
       mode: str = "managed") -> dict[str, Any]:
    kind = address.split(".")[0] if mode == "managed" else address.split(".")[1]
    return {"address": address, "mode": mode, "type": kind, "name": "x",
            "change": {"actions": actions, "before": None, "after": after,
                       "after_unknown": after_unknown if after_unknown is not None else {}}}


def plan(*changes: dict[str, Any], **extra: Any) -> dict[str, Any]:
    return {"format_version": "1.2", "terraform_version": "1.15.8", "resource_changes": list(changes),
            **extra}


def task_def(actions: list[str], *, env: list[dict[str, str]] | None = None,
             secrets: list[dict[str, str]] | None = None, env_files: bool = False) -> dict[str, Any]:
    container: dict[str, Any] = {"name": "maker-paper", "image": "x/pmbot:abc",
                                 "environment": PAPER_ENV if env is None else env}
    if secrets is not None:
        container["secrets"] = secrets
    if env_files:
        container["environmentFiles"] = [{"type": "s3", "value": "arn:aws:s3:::b/live.env"}]
    return raw_task_def(container, actions)


def raw_task_def(container: Any, actions: list[str] | None = None) -> dict[str, Any]:
    """A maker-paper task-definition change whose container_definitions holds exactly `container`."""
    after = {"family": "pmbot-maker-paper", "container_definitions": json.dumps([container])}
    return rc('aws_ecs_task_definition.svc["maker-paper"]', actions or ["create"], after=after)


def evaluate(p: dict[str, Any]) -> tuple[list[str], list[str]]:
    return plan_guard.evaluate(p)


class DestructiveChanges(unittest.TestCase):
    def test_the_guarded_types_are_exactly_the_eleven_of_ruling_10(self) -> None:
        self.assertEqual(plan_guard.GUARDED_TYPES, frozenset({
            # the change brief's seven
            "aws_ecs_cluster", "aws_autoscaling_group", "aws_launch_template", "aws_ecr_repository",
            "aws_iam_role", "aws_cloudwatch_log_group", "aws_s3_bucket",
            # CH-008 planner ruling 10
            "aws_ecs_service", "aws_ecs_capacity_provider", "aws_ecs_cluster_capacity_providers",
            "aws_iam_instance_profile",
        }))
        self.assertEqual(len(plan_guard.GUARDED_TYPES), 11)

    def test_creates_and_in_place_updates_of_guarded_types_pass(self) -> None:
        changes = [rc(f"{t}.x", ["create"]) for t in sorted(plan_guard.GUARDED_TYPES)]
        changes += [rc(f"{t}.y", ["update"]) for t in sorted(plan_guard.GUARDED_TYPES)]
        changes += [rc(f"{t}.z", ["no-op"]) for t in sorted(plan_guard.GUARDED_TYPES)]
        self.assertEqual(evaluate(plan(*changes))[0], [])

    def test_every_delete_or_replace_of_a_guarded_type_is_refused(self) -> None:
        """Mutation-checked: dropping the `"delete" in actions` test makes every subTest fail."""
        for kind in sorted(plan_guard.GUARDED_TYPES):
            for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
                with self.subTest(kind=kind, actions=actions):
                    refusals, _ = evaluate(plan(rc(f"{kind}.this", actions)))
                    self.assertEqual(len(refusals), 1)
                    self.assertIn(f"`{kind}.this`", refusals[0])

    def test_deletes_and_replaces_of_other_types_pass(self) -> None:
        changes = [rc("aws_cloudwatch_metric_alarm.service_down[\"recorder\"]", ["delete"]),
                   rc("aws_iam_role_policy.task", ["delete", "create"]),
                   rc("aws_scheduler_schedule.daily_ingest", ["update"]),
                   rc("aws_cloudwatch_log_metric_filter.daily_ingest_ok", ["create", "delete"]),
                   task_def(["delete", "create"])]
        self.assertEqual(evaluate(plan(*changes))[0], [])

    def test_data_sources_are_ignored(self) -> None:
        """Mutation-checked: drop the mode filter in managed_changes and both subTests are refused.
        Each change would be refused if it were managed (a guarded delete; unparseable containers)."""
        for change in (rc("data.aws_iam_role.x", ["delete"], mode="data"),
                       rc("data.aws_ecs_task_definition.x", ["create"], mode="data",
                          after={"container_definitions": "not json"})):
            with self.subTest(address=change["address"]):
                self.assertEqual(evaluate(plan(change)), ([], []))

    def test_an_errored_plan_is_refused(self) -> None:
        refusals, _ = evaluate(plan(errored=True))
        self.assertEqual(refusals, ["the plan is marked errored"])


class CdRoles(unittest.TestCase):
    def test_any_change_to_a_github_role_or_policy_is_refused(self) -> None:
        """Mutation-checked: remove cd_role_refusals from evaluate() and the creates pass."""
        for address, actions in (("aws_iam_role.github_deploy", ["create"]),
                                 ("aws_iam_role_policy.github_terraform", ["update"]),
                                 ("aws_iam_role_policy.github_push", ["delete", "create"]),
                                 ("aws_iam_role.github_terraform_plan", ["forget"])):
            with self.subTest(address=address):
                refusals, _ = evaluate(plan(rc(address, actions)))
                self.assertTrue(refusals)
                self.assertTrue(any("owner-applied" in r for r in refusals))

    def test_no_op_on_github_roles_and_changes_to_other_roles_pass(self) -> None:
        changes = [rc("aws_iam_role.github_push", ["no-op"]),
                   rc("aws_iam_role_policy.github_deploy", ["no-op"]),
                   rc("aws_iam_role_policy.task", ["update"]),
                   rc("aws_iam_role.scheduler", ["update"])]
        self.assertEqual(evaluate(plan(*changes))[0], [])


class PaperOnly(unittest.TestCase):
    def test_the_paper_maker_passes(self) -> None:
        refusals, notes = evaluate(plan(task_def(["delete", "create"])))
        self.assertEqual(refusals, [])
        self.assertEqual(notes, ['aws_ecs_task_definition.svc["maker-paper"]'])

    def test_live_trading_settings_are_refused(self) -> None:
        """Mutation-checked: remove paper_refusals from evaluate() and every subTest fails."""
        cases = {
            "LIVE_ENABLE_ env": task_def(["create"], env=[*PAPER_ENV, {"name": "LIVE_ENABLE_NBA", "value": "1"}]),
            "lower-case env": task_def(["update"], env=[{"name": "live_enable_nhl", "value": "1"}]),
            "POLYMARKET_ env": task_def(["create"], env=[{"name": "POLYMARKET_API_KEY", "value": "x"}]),
            "LIVE_TRADING=1": task_def(["delete", "create"], env=[{"name": "LIVE_TRADING", "value": "1"}]),
            "POLYMARKET_ secret": task_def(["create"], secrets=[{"name": "POLYMARKET_PRIVATE_KEY",
                                                                 "valueFrom": "arn:x"}]),
            "LIVE_TRADING secret": task_def(["create"], secrets=[{"name": "LIVE_TRADING", "valueFrom": "arn:x"}]),
            "environmentFiles": task_def(["create"], env_files=True),
        }
        for label, change in cases.items():
            with self.subTest(label):
                refusals, _ = evaluate(plan(change))
                self.assertEqual(len(refusals), 1, refusals)
                self.assertIn('aws_ecs_task_definition.svc["maker-paper"]', refusals[0])

    def test_key_case_padding_and_non_object_entries_are_refused(self) -> None:
        """Mutation-checked: drop _lower_keys, the .strip() or the non-object branch and a subTest fails."""
        base = {"name": "maker-paper", "image": "x/pmbot:abc"}
        cases = {
            "Environment key, no value": ({**base, "Environment": [{"name": "LIVE_ENABLE_NBA"}]},
                                          "environment LIVE_ENABLE_NBA"),
            "Name/Value keys": ({**base, "environment": [{"Name": "LIVE_TRADING", "Value": "1"}]},
                                "environment LIVE_TRADING='1'"),
            "padded name": ({**base, "environment": [{"name": " LIVE_ENABLE_NBA", "value": "1"}]},
                            "environment LIVE_ENABLE_NBA"),
            "SECRETS key": ({**base, "Secrets": [{"NAME": "polymarket_pk", "valueFrom": "arn:x"}]},
                            "secret POLYMARKET_PK"),
            "string entry": ({**base, "environment": ["LIVE_TRADING=1"]}, "is not an object"),
            "environment not a list": ({**base, "environment": {"LIVE_TRADING": "1"}}, "is not a list"),
            "container not an object": ("maker-paper", "a container definition is not an object"),
        }
        for label, (container, expected) in cases.items():
            with self.subTest(label):
                refusals, _ = evaluate(plan(raw_task_def(container)))
                self.assertEqual(len(refusals), 1, refusals)
                self.assertIn('aws_ecs_task_definition.svc["maker-paper"]', refusals[0])
                self.assertIn(expected, refusals[0])

    def test_keys_differing_only_in_case_are_refused(self) -> None:
        container = {"name": "maker-paper", "environment": PAPER_ENV, "ENVIRONMENT": []}
        refusals, _ = evaluate(plan(raw_task_def(container)))
        self.assertEqual(len(refusals), 1, refusals)
        self.assertIn("keys differ only in case (environment)", refusals[0])

    def test_unknown_or_unparseable_container_definitions_are_refused(self) -> None:
        unknown = rc("aws_ecs_task_definition.daily_ingest", ["create"], after={"family": "f"},
                     after_unknown={"container_definitions": True})
        garbage = rc("aws_ecs_task_definition.daily_ingest", ["create"],
                     after={"container_definitions": "not json"})
        not_list = rc("aws_ecs_task_definition.daily_ingest", ["create"],
                      after={"container_definitions": json.dumps({"name": "x"})})
        for change in (unknown, garbage, not_list):
            with self.subTest(change=change["change"]["after"]):
                refusals, _ = evaluate(plan(change))
                self.assertEqual(len(refusals), 1, refusals)

    def test_a_task_definition_delete_is_not_inspected(self) -> None:
        refusals, notes = evaluate(plan(rc("aws_ecs_task_definition.daily_ingest", ["delete"])))
        self.assertEqual((refusals, notes), ([], []))


class Cli(unittest.TestCase):
    def run_main(self, content: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "plan.json"
            path.write_text(content, encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = plan_guard.main([str(path)])
        return code, out.getvalue()

    def test_ok_plan_exits_0_with_counts_and_a_rollout_note(self) -> None:
        code, out = self.run_main(json.dumps(plan(rc("aws_iam_role_policy.task", ["update"]),
                                                  task_def(["delete", "create"]))))
        self.assertEqual(code, plan_guard.EXIT_OK)
        self.assertTrue(out.startswith("#### plan_guard: OK to apply"))
        self.assertIn("create 0, update 1, replace 1, delete 0", out)
        self.assertIn("pmbot-deploy", out)

    def test_refused_plan_exits_1(self) -> None:
        code, out = self.run_main(json.dumps(plan(rc("aws_ecs_cluster.pmbot", ["delete", "create"]))))
        self.assertEqual(code, plan_guard.EXIT_REFUSED)
        self.assertTrue(out.startswith("#### plan_guard: REFUSED"))
        self.assertIn("`aws_ecs_cluster.pmbot`", out)

    def test_unreadable_input_exits_2(self) -> None:
        for content in ("not json", "[]", json.dumps({"resource_changes": []}),
                        json.dumps({"format_version": "1.2", "resource_changes": {}}),
                        json.dumps({"format_version": "1.2", "resource_changes": [{"address": "a"}]})):
            with self.subTest(content=content):
                code, out = self.run_main(content)
                self.assertEqual(code, plan_guard.EXIT_UNREADABLE)
                self.assertIn("REFUSED (unreadable plan)", out)

    def test_a_plan_without_resource_changes_is_ok(self) -> None:
        code, out = self.run_main(json.dumps({"format_version": "1.2"}))
        self.assertEqual(code, plan_guard.EXIT_OK)
        self.assertIn("create 0, update 0, replace 0, delete 0", out)


if __name__ == "__main__":
    unittest.main()
