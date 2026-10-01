"""Tests for plan_guard.py (polymarket-bot CH-008-T4). Stdlib unittest, no Terraform, no AWS:

    python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v    # from the repo root
"""

from __future__ import annotations

import contextlib
import io
import json
import re
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
                   rc("aws_iam_role_policy.scheduler", ["delete", "create"]),
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
                   rc("aws_iam_role_policy.scheduler", ["update"]),
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
        code, out = self.run_main(json.dumps(plan(rc("aws_iam_role_policy.scheduler", ["update"]),
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


PMBOT = Path(__file__).resolve().parents[1]
BUCKET = plan_guard.DATA_BUCKET
SSM_LIVE_ARN = "arn:aws:ssm:us-east-1:123456789012:parameter/pmbot/live/*"
EXEC_CHANNELS = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
                 "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]


def arn(key: str = "") -> str:
    return f"arn:aws:s3:::{BUCKET}" + (f"/{key}" if key else "")


def stmt(sid: str, effect: str, action: Any, resource: Any, **extra: Any) -> dict[str, Any]:
    return {"Sid": sid, "Effect": effect, "Action": action, "Resource": resource, **extra}


def delete_deny() -> dict[str, Any]:
    return stmt("NeverDeleteOrReconfigure", "Deny",
                ["s3:Delete*", "s3:PutBucket*", "s3:PutLifecycleConfiguration"], [arn(), arn("*")])


def plane_statements(plane: str) -> list[dict[str, Any]]:
    """What iam.tf's aws_iam_role_policy.plane renders for `plane` (an exec plane)."""
    return [
        stmt("ReadData", "Allow", ["s3:GetObject"], arn("sports/*")),
        stmt("ListData", "Allow", ["s3:ListBucket"], arn()),
        stmt("WriteOwnPrefixes", "Allow", ["s3:PutObject", "s3:AbortMultipartUpload"],
             [arn(f"sports/{prefix}*") for prefix in plan_guard.PLANE_WRITE_PREFIXES[plane]]),
        delete_deny(),
        stmt("EcsExecChannels", "Allow", EXEC_CHANNELS, "*"),
    ]


def policy_change(address: str, statements: list[dict[str, Any]], actions: list[str] | None = None, *,
                  role: str | None = None, before: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    after: dict[str, Any] = {"name": "x", "policy": json.dumps({"Version": "2012-10-17", "Statement": statements})}
    if role is not None:
        after["role"] = role
    entry = rc(address, actions or ["create"], after=after)
    if before is not None:
        entry["change"]["before"] = {"policy": json.dumps({"Version": "2012-10-17", "Statement": before})}
    return entry


def plane_change(plane: str, statements: list[dict[str, Any]] | None = None,
                 actions: list[str] | None = None) -> dict[str, Any]:
    return policy_change(f'aws_iam_role_policy.plane["{plane}"]', statements or plane_statements(plane),
                         actions, role=f"pmbot-task-{plane}")


def with_statement(plane: str, sid: str, **changes: Any) -> list[dict[str, Any]]:
    """plane_statements(plane) with the statement `sid` updated (a value of None removes the key)."""
    out = []
    for item in plane_statements(plane):
        if item["Sid"] == sid:
            item = {key: value for key, value in {**item, **changes}.items() if value is not None}
        out.append(item)
    return out


def refusals_of(*changes: dict[str, Any]) -> list[str]:
    return evaluate(plan(*changes))[0]


def iam_planes() -> dict[str, tuple[str, ...]]:
    """`local.planes` of iam.tf: plane -> write_prefixes (stdlib parse of the block's fixed layout)."""
    text = (PMBOT / "iam.tf").read_text(encoding="utf-8")
    block = re.search(r"^  planes = \{\n(.*?)^  \}\n", text, re.M | re.S)
    assert block is not None, "local.planes not found in iam.tf"
    found: dict[str, tuple[str, ...]] = {}
    for plane in re.finditer(r"^    (?P<name>[a-z]+) = \{\n(?P<body>.*?)^    \}\n", block.group(1), re.M | re.S):
        listed = re.search(r"write_prefixes\s*=\s*\[(.*?)\]", plane["body"], re.S)
        assert listed is not None, f"no write_prefixes in plane {plane['name']}"
        found[plane["name"]] = tuple(re.findall(r'"([^"]*)"', listed.group(1)))
    return found


# The only cross-plane prefix overlaps (plan head "S3 prefix ownership"); every other pair of (plane, prefix) across
# two planes is disjoint. Each entry is one overlapping pair; the test is an exact set, so a new overlap and a stale
# entry both fail. An overlap means two roles may write the same keys: add one only with its writer named.
ALLOWED_OVERLAPS: frozenset[frozenset[tuple[str, str]]] = frozenset(frozenset(pair) for pair in (
    (("model", "recorder/nba_injury/"), ("collect", "recorder/")),       # daily-ingest runs the injury fetcher
    (("research", "nba/"), ("model", "nba/")),                            # hand-run research ingests
    (("research", "nhl/"), ("model", "nhl/")),
    (("research", "collectors/xvenue/"), ("collect", "collectors/")),    # xvenue_analyze.py
    (("paper", "nba/injury_parsed/"), ("model", "nba/")),                 # inline maker path, until CHORE-015 (T11)
    (("paper", "nba/injury_parsed/"), ("research", "nba/")),              # inline maker path, until CHORE-015 (T11)
))


def prefix_overlaps() -> set[frozenset[tuple[str, str]]]:
    """Every pair of (plane, prefix) from two different planes where one prefix is a prefix of the other."""
    items = [(plane, prefix) for plane, prefixes in plan_guard.PLANE_WRITE_PREFIXES.items() for prefix in prefixes]
    return {frozenset((a, b)) for i, a in enumerate(items) for b in items[i + 1:]
            if a[0] != b[0] and (a[1].startswith(b[1]) or b[1].startswith(a[1]))}


class RolePolicies(unittest.TestCase):
    def test_the_four_planes_as_iam_tf_renders_them_pass(self) -> None:
        for plane in plan_guard.PLANE_WRITE_PREFIXES:
            with self.subTest(plane=plane):
                self.assertEqual(refusals_of(plane_change(plane)), [])
                self.assertEqual(refusals_of(plane_change(plane, actions=["update"])), [])

    def test_a_write_outside_the_planes_prefixes_is_refused(self) -> None:
        """Mutation-checked: make _write_target_ok return True and every subTest fails."""
        cases = {
            "paper writes recorder rows": ("paper", "sports/recorder/*"),
            "model writes the paper journal": ("model", "sports/live/maker/journal.paper.*"),
            "collect writes predictions": ("collect", "sports/predictions/*"),
            "research writes predictions": ("research", "sports/predictions/*"),
            "prefix widened to sports/": ("paper", "sports/*"),
            "prefix widened by a wildcard": ("paper", "sports/live/*"),
            "bucket-wide object ARN": ("collect", "*"),
            "the bucket ARN itself": ("collect", ""),
            "outside sports/": ("collect", "recorder/*"),
        }
        for label, (plane, key) in cases.items():
            with self.subTest(label):
                resource = [arn(key), *[arn(f"sports/{p}*") for p in plan_guard.PLANE_WRITE_PREFIXES[plane]]]
                refusals = refusals_of(plane_change(plane, with_statement(plane, "WriteOwnPrefixes",
                                                                          Resource=resource)))
                self.assertEqual(len(refusals), 1, refusals)
                self.assertIn("outside the plane's prefixes", refusals[0])

    def test_a_write_to_a_foreign_bucket_is_refused(self) -> None:
        other = "arn:aws:s3:::some-other-bucket/sports/recorder/*"
        refusals = refusals_of(plane_change("collect", with_statement("collect", "WriteOwnPrefixes",
                                                                      Resource=[other])))
        self.assertTrue(any("outside the data bucket" in r for r in refusals), refusals)

    def test_wildcard_and_unlisted_actions_are_refused(self) -> None:
        """Mutation-checked: drop the wildcard branch and the `ssmmessages:*` subTest fails; drop the S3
        allow-list and four subTests fail."""
        for action in ("s3:*", "*", "ssmmessages:*", "s3:Put*", "s3:PutObjectAcl", "s3:DeleteObject",
                       "s3:GetObject*", "ecs:RunTask", "iam:PassRole", "sts:AssumeRole"):
            with self.subTest(action=action):
                statements = [*plane_statements("collect"), stmt("Extra", "Allow", [action], arn("sports/recorder/*"))]
                refusals = refusals_of(plane_change("collect", statements))
                self.assertEqual(len(refusals), 1, refusals)
                self.assertIn("statement Extra", refusals[0])

    def test_a_missing_or_weak_delete_deny_is_refused(self) -> None:
        """Mutation-checked: make _has_delete_deny return True and every subTest fails."""
        no_deny = [s for s in plane_statements("paper") if s["Effect"] == "Allow"]
        objects_only = [s if s["Effect"] == "Allow" else {**s, "Resource": [arn("*")]} for s in plane_statements("paper")]
        bucket_only = [s if s["Effect"] == "Allow" else {**s, "Resource": [arn()]} for s in plane_statements("paper")]
        narrower = [s if s["Effect"] == "Allow" else {**s, "Action": ["s3:DeleteObject*"]}
                    for s in plane_statements("paper")]
        conditional = [s if s["Effect"] == "Allow" else {**s, "Condition": {"Bool": {"aws:SecureTransport": "false"}}}
                       for s in plane_statements("paper")]
        allowed_as_deny = [{**s, "Effect": "Allow"} if s["Effect"] == "Deny" else s for s in plane_statements("paper")]
        for label, statements in (("no deny", no_deny), ("objects only", objects_only), ("bucket only", bucket_only),
                                  ("DeleteObject* only", narrower), ("conditional", conditional),
                                  ("Deny turned into Allow", allowed_as_deny)):
            with self.subTest(label):
                refusals = refusals_of(plane_change("paper", statements))
                self.assertTrue(any("Deny of s3:Delete*" in r for r in refusals), refusals)

    def test_ssm_parameter_access_is_refused_on_every_plane_role(self) -> None:
        """Refused twice (the ssm branch, and the service allow-list); the live-role test below pins the
        branch itself."""
        for plane in plan_guard.PLANE_WRITE_PREFIXES:
            for action in ("ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:*"):
                with self.subTest(plane=plane, action=action):
                    statements = [*plane_statements(plane), stmt("Params", "Allow", [action], SSM_LIVE_ARN)]
                    refusals = refusals_of(plane_change(plane, statements))
                    self.assertTrue(any("statement Params" in r for r in refusals), refusals)

    def test_ssm_live_parameters_are_allowed_only_on_the_live_role(self) -> None:
        reads = [s for s in plane_statements("paper") if s["Sid"] in ("ReadData", "ListData", "NeverDeleteOrReconfigure")]
        params = stmt("ReadLiveParameters", "Allow", ["ssm:GetParameter", "ssm:GetParameters"], SSM_LIVE_ARN)
        live = policy_change("aws_iam_role_policy.live", [*reads, params], role="pmbot-task-live")
        self.assertEqual(refusals_of(live), [])
        other_path = stmt("Params", "Allow", ["ssm:GetParameter"], "arn:aws:ssm:us-east-1:123456789012:parameter/pmbot/*")
        refusals = refusals_of(policy_change("aws_iam_role_policy.live", [*reads, other_path], role="pmbot-task-live"))
        self.assertTrue(any("outside /pmbot/live/" in r for r in refusals), refusals)
        sibling = stmt("Params", "Allow", ["ssm:GetParameter"], "arn:aws:ssm:us-east-1:123456789012:parameter/pmbot/livex/*")
        self.assertTrue(refusals_of(policy_change("aws_iam_role_policy.live", [*reads, sibling], role="pmbot-task-live")))
        # the live role has no S3 write prefixes until EP-033 adds them
        write = stmt("W", "Allow", ["s3:PutObject"], arn("sports/live/maker/journal.live.jsonl"))
        refusals = refusals_of(policy_change("aws_iam_role_policy.live", [*reads, params, write], role="pmbot-task-live"))
        self.assertTrue(any("outside the plane's prefixes" in r for r in refusals), refusals)

    def test_an_unreadable_or_unknown_policy_is_refused_like_container_definitions(self) -> None:
        unknown = plane_change("model")
        unknown["change"]["after"].pop("policy")
        unknown["change"]["after_unknown"] = {"policy": True}
        garbage = plane_change("model")
        garbage["change"]["after"]["policy"] = "not json"
        no_statements = plane_change("model")
        no_statements["change"]["after"]["policy"] = json.dumps({"Version": "2012-10-17"})
        not_objects = plane_change("model")
        not_objects["change"]["after"]["policy"] = json.dumps({"Statement": ["s3:*"]})
        for label, change in (("unknown", unknown), ("garbage", garbage), ("no Statement", no_statements),
                              ("string statement", not_objects)):
            with self.subTest(label):
                refusals = refusals_of(change)
                self.assertEqual(len(refusals), 1, refusals)
                self.assertIn('aws_iam_role_policy.plane["model"]', refusals[0])

    def test_not_action_and_not_resource_cannot_be_checked_and_are_refused(self) -> None:
        for key in ("NotAction", "NotResource"):
            with self.subTest(key):
                statements = [*plane_statements("collect"), {"Sid": "Odd", "Effect": "Allow", key: ["s3:*"],
                                                             "Resource": "*"}]
                refusals = refusals_of(plane_change("collect", statements))
                self.assertTrue(any("cannot be scope-checked" in r for r in refusals), refusals)

    def test_a_plane_policy_attached_to_the_wrong_role_is_refused(self) -> None:
        change = plane_change("paper")
        change["change"]["after"]["role"] = "pmbot-task-model"
        refusals = refusals_of(change)
        self.assertEqual(len(refusals), 1, refusals)
        self.assertIn("attached to pmbot-task-model, not pmbot-task-paper", refusals[0])

    def test_an_unknown_plane_has_no_prefixes_and_cannot_write(self) -> None:
        refusals = refusals_of(plane_change("live", plane_statements("paper")))
        self.assertTrue(any("outside the plane's prefixes" in r for r in refusals), refusals)

    def test_another_policy_on_a_task_role_is_checked_like_a_plane_policy(self) -> None:
        widened = [stmt("W", "Allow", ["s3:PutObject"], arn("*")), delete_deny()]
        refusals = refusals_of(policy_change("aws_iam_role_policy.extra", widened, role="pmbot-task-model"))
        self.assertTrue(any("outside the plane's prefixes" in r for r in refusals), refusals)

    def test_policies_of_other_roles_are_not_inspected(self) -> None:
        scheduler = policy_change("aws_iam_role_policy.scheduler",
                                  [stmt("Run", "Allow", "ecs:RunTask", "*")], role="pmbot-scheduler")
        execution = policy_change("aws_iam_role_policy.execution", [stmt("Logs", "Allow", "logs:*", "*")],
                                  role="pmbot-task-execution")
        unrelated = rc("aws_iam_role_policy.scheduler", ["update"], after={"policy": "unknown"})
        self.assertEqual(refusals_of(scheduler, execution, unrelated), [])

    def test_a_delete_or_no_op_is_not_inspected(self) -> None:
        for actions in (["delete"], ["no-op"], ["read"]):
            with self.subTest(actions=actions):
                change = plane_change("paper", [stmt("Bad", "Allow", ["*"], "*")], actions)
                self.assertEqual(refusals_of(change), [])

    def test_a_managed_policy_on_a_task_role_is_refused(self) -> None:
        admin = {"role": "pmbot-task-model", "policy_arn": "arn:aws:iam::aws:policy/AdministratorAccess"}
        for role in ("pmbot-task-model", "pmbot-task", "pmbot-task-live"):
            with self.subTest(role=role):
                refusals = refusals_of(rc("aws_iam_role_policy_attachment.x", ["create"], after={**admin, "role": role}))
                self.assertEqual(len(refusals), 1, refusals)
                self.assertIn("inline policies only", refusals[0])
        for role in ("pmbot-task-execution", "pmbot-ecs-instance"):
            with self.subTest(role=role):
                self.assertEqual(refusals_of(rc("aws_iam_role_policy_attachment.x", ["create"],
                                                after={**admin, "role": role})), [])


class LegacyTaskRole(unittest.TestCase):
    OLD = [
        stmt("DataObjects", "Allow", ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"], arn("*")),
        stmt("DataBucketList", "Allow", ["s3:ListBucket"], arn()),
        stmt("NeverDeleteOrReconfigure", "Deny", ["s3:DeleteObject*", "s3:PutBucket*"], [arn(), arn("*")]),
        stmt("ReadPmbotParameters", "Allow", ["ssm:GetParameter"], "arn:aws:ssm:us-east-1:123456789012:parameter/pmbot/*"),
        stmt("EcsExecChannels", "Allow", EXEC_CHANNELS, "*"),
    ]

    def legacy(self, after: list[dict[str, Any]], actions: list[str], before: list[dict[str, Any]] | None) -> Any:
        return policy_change("aws_iam_role_policy.task", after, actions, role="pmbot-task", before=before)

    def test_dropping_the_ssm_statement_in_place_passes(self) -> None:
        after = [s for s in self.OLD if s["Sid"] != "ReadPmbotParameters"]
        self.assertEqual(refusals_of(self.legacy(after, ["update"], self.OLD)), [])
        self.assertEqual(refusals_of(self.legacy(self.OLD, ["update"], self.OLD)), [])

    def test_the_legacy_policy_may_not_gain_or_change_a_statement(self) -> None:
        """Mutation-checked: make _legacy_problems return [] and every subTest fails."""
        gained = [*self.OLD, stmt("More", "Allow", ["ec2:*"], "*")]
        widened = [{**s, "Resource": "*"} if s["Sid"] == "DataBucketList" else s for s in self.OLD]
        for label, after in (("new statement", gained), ("changed statement", widened)):
            with self.subTest(label):
                refusals = refusals_of(self.legacy(after, ["update"], self.OLD))
                self.assertEqual(len(refusals), 1, refusals)
                self.assertIn("may only lose statements", refusals[0])

    def test_a_create_from_an_empty_state_passes_but_an_unreadable_policy_does_not(self) -> None:
        self.assertEqual(refusals_of(self.legacy(self.OLD, ["create"], None)), [])
        unknown = self.legacy(self.OLD, ["update"], self.OLD)
        unknown["change"]["after"].pop("policy")
        unknown["change"]["after_unknown"] = {"policy": True}
        self.assertEqual(len(refusals_of(unknown)), 1)

    def test_the_legacy_policy_is_recognised_by_role_name_too(self) -> None:
        gained = [*self.OLD, stmt("More", "Allow", ["ec2:*"], "*")]
        change = policy_change("aws_iam_role_policy.renamed", gained, ["update"], role="pmbot-task", before=self.OLD)
        self.assertEqual(len(refusals_of(change)), 1)


class PlanePrefixes(unittest.TestCase):
    def test_plane_prefixes_equal_iam_tf(self) -> None:
        """iam.tf `local.planes` and plan_guard.PLANE_WRITE_PREFIXES are one list kept twice: edit both."""
        found = iam_planes()
        self.assertEqual(sorted(found), ["collect", "model", "paper", "research"])
        self.assertEqual(found, {plane: tuple(prefixes) for plane, prefixes in plan_guard.PLANE_WRITE_PREFIXES.items()})

    def test_every_prefix_is_a_relative_literal(self) -> None:
        for plane, prefixes in plan_guard.PLANE_WRITE_PREFIXES.items():
            for prefix in prefixes:
                with self.subTest(plane=plane, prefix=prefix):
                    self.assertTrue(prefix and not prefix.startswith("/") and not set("*?") & set(prefix))

    def test_planes_overlap_only_where_allowed_and_are_otherwise_disjoint(self) -> None:
        """Every cross-plane overlap is in ALLOWED_OVERLAPS and every entry still overlaps (exact set). Mutation-
        checked: add "recorder/" to paper, or drop "nba/injury_parsed/" from paper without dropping its two
        entries, and this fails."""
        found = prefix_overlaps()
        self.assertEqual(sorted(sorted(pair) for pair in found - ALLOWED_OVERLAPS), [],
                         "planes overlap outside ALLOWED_OVERLAPS")
        self.assertEqual(sorted(sorted(pair) for pair in ALLOWED_OVERLAPS - found), [],
                         "stale ALLOWED_OVERLAPS entry")

    def test_data_bucket_equals_variables_tf(self) -> None:
        text = (PMBOT / "variables.tf").read_text(encoding="utf-8")
        match = re.search(r'variable "data_bucket" \{.*?default\s*=\s*"([^"]+)"', text, re.S)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), plan_guard.DATA_BUCKET)  # type: ignore[union-attr]


class RolePolicyReport(unittest.TestCase):
    def test_a_refused_role_policy_fails_the_cli_and_names_the_policy(self) -> None:
        widened = plane_change("paper", with_statement("paper", "WriteOwnPrefixes", Resource=[arn("*")]))
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "plan.json"
            path.write_text(json.dumps(plan(widened)), encoding="utf-8")
            with contextlib.redirect_stdout(out):
                code = plan_guard.main([str(path)])
        self.assertEqual(code, plan_guard.EXIT_REFUSED)
        self.assertIn('`aws_iam_role_policy.plane["paper"]` (create)', out.getvalue())

    def test_the_pr_a_plan_shape_passes(self) -> None:
        """Four roles and four plane policies created, the legacy policy shrunk, the scheduler policy and the
        ECR lifecycle updated in place: what PR A plans."""
        changes = [rc(f'aws_iam_role.plane["{p}"]', ["create"]) for p in plan_guard.PLANE_WRITE_PREFIXES]
        changes += [plane_change(p) for p in plan_guard.PLANE_WRITE_PREFIXES]
        old = LegacyTaskRole.OLD
        changes.append(policy_change("aws_iam_role_policy.task", [s for s in old if s["Sid"] != "ReadPmbotParameters"],
                                     ["update"], role="pmbot-task", before=old))
        changes += [rc("aws_iam_role_policy.scheduler", ["update"]), rc("aws_ecr_lifecycle_policy.pmbot", ["update"])]
        refusals, notes = evaluate(plan(*changes))
        self.assertEqual((refusals, notes), ([], []))
        self.assertEqual(plan_guard.counts(plan_guard.managed_changes(plan(*changes))),
                         {"create": 8, "update": 3, "replace": 0, "delete": 0})


class PlaneRevisions(unittest.TestCase):
    """PR B (`task_role_arn` and SPORTS_S3_QUEUE per family) and PR C (the per-target image) replace every
    task definition and change nothing else the guard knows about."""

    ADDRESSES = {
        'aws_ecs_task_definition.svc["recorder"]': ("recorder", "collect"),
        'aws_ecs_task_definition.svc["maker-paper"]': ("maker-paper", "paper"),
        'aws_ecs_task_definition.svc["ingame-capture"]': ("ingame-capture", "collect"),
        'aws_ecs_task_definition.svc["xvenue-poller"]': ("xvenue-poller", "collect"),
        'aws_ecs_task_definition.svc["rewards-poll"]': ("rewards-poll", "collect"),
        "aws_ecs_task_definition.daily_ingest": ("daily-ingest", "model"),
        "aws_ecs_task_definition.predictor": ("predictor", "model"),
    }

    def replaced(self, queue: str = "plane") -> list[dict[str, Any]]:
        out = []
        for address, (family, plane) in self.ADDRESSES.items():
            env = [*PAPER_ENV, {"name": "SPORTS_S3_QUEUE", "value": plane if queue == "plane" else queue}]
            containers = json.dumps([{"name": family, "image": f"x/pmbot:abc-{plane}", "environment": env}])
            out.append(rc(address, ["delete", "create"], after={"family": f"pmbot-{family}",
                                                                "container_definitions": containers}))
        return out

    def test_the_seven_replaced_task_definitions_pass_and_are_listed_for_the_rollout(self) -> None:
        refusals, notes = evaluate(plan(*self.replaced()))
        self.assertEqual(refusals, [])
        self.assertEqual(sorted(notes), sorted(self.ADDRESSES))
        self.assertEqual(plan_guard.counts(plan_guard.managed_changes(plan(*self.replaced()))),
                         {"create": 0, "update": 0, "replace": 7, "delete": 0})

    def test_a_live_setting_slipped_into_one_of_them_is_still_refused(self) -> None:
        changes = self.replaced()
        changes[1] = task_def(["delete", "create"], env=[{"name": "LIVE_TRADING", "value": "1"}])
        refusals, _ = evaluate(plan(*changes))
        self.assertEqual(len(refusals), 1, refusals)


if __name__ == "__main__":
    unittest.main()
