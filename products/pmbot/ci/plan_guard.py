#!/usr/bin/env python3
"""Safety gate between `terraform plan -out` and `apply` for products/pmbot (polymarket-bot CH-008).

    terraform show -json tfplan > plan.json
    python3 ci/plan_guard.py plan.json      # exit 0 = may apply, 1 = refused, 2 = unreadable plan

Refuses (exit 1) a plan that
  * deletes or replaces a resource of a GUARDED_TYPES type: the cluster, its capacity provider and
    provider list, the services, the ASG, the launch template, the ECR repository, IAM roles and the
    instance profile, log groups, or a bucket;
  * changes a GitHub OIDC role or its policy (CD never edits its own permissions; the owner applies
    those from a saved plan);
  * creates or updates a task role's inline policy outside its plane (EP-031): a write grant outside the
    plane's S3 prefixes, a wildcard action, no unconditional Deny of s3:Delete* on the bucket, any SSM
    parameter access (except /pmbot/live/* on pmbot-task-live) or a managed policy attached to a task role
    through aws_iam_role_policy_attachment (not checked: a role unknown at plan time, aws_iam_role
    managed_policy_arns / inline_policy, aws_iam_policy_attachment, aws_iam_role_policies_exclusive);
  * gives a task definition a live-trading setting: a LIVE_ENABLE_* or POLYMARKET_* variable or secret
    (any case), LIVE_TRADING anywhere but the environment value "0", an environmentFiles entry, or
    container definitions unknown at plan time. Paper only, with the same rules as polymarket-bot
    deploy/pmbot/ecs_deploy.py;
  * is marked errored.
Creates, in-place updates, and deletes or replaces of every other type pass. Prints a Markdown report
(for the PR comment and the job summary) on stdout. Stdlib only, Python >= 3.12."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

GUARDED_TYPES = frozenset({
    # the change brief's list
    "aws_ecs_cluster", "aws_autoscaling_group", "aws_launch_template", "aws_ecr_repository",
    "aws_iam_role", "aws_cloudwatch_log_group", "aws_s3_bucket",
    # deleting these also takes the stack down (CH-008 planner ruling 10)
    "aws_ecs_service", "aws_ecs_capacity_provider", "aws_ecs_cluster_capacity_providers",
    "aws_iam_instance_profile",
})
CD_ROLE_ADDRESS = re.compile(r"^aws_iam_role(_policy)?\.github_")
TASK_DEFINITION = "aws_ecs_task_definition"
INERT_ACTIONS = frozenset({"no-op", "read"})
POLICY_TYPE = "aws_iam_role_policy"
ATTACHMENT_TYPE = "aws_iam_role_policy_attachment"
PLANE_ROLE = re.compile(r'^aws_iam_role_policy\.plane\["(?P<plane>[a-z]+)"\]$')
TASK_ROLE = re.compile(r"^pmbot-task(-[a-z0-9-]+)?$")
EXECUTION_ROLE = "pmbot-task-execution"
LEGACY_ROLE = "pmbot-task"
LEGACY_POLICY_ADDRESS = "aws_iam_role_policy.task"
LIVE_ROLE = "pmbot-task-live"   # EP-033; the only role that may read SSM parameters, and only /pmbot/live/*
DATA_BUCKET = "polymarket-bot-data-339713122183"   # variables.tf data_bucket (a test pins the two equal)
BUCKET_ARN = f"arn:aws:s3:::{DATA_BUCKET}"
SPORTS_ARN = f"{BUCKET_ARN}/sports/"
SSM_LIVE = re.compile(r"^arn:aws:ssm:[a-z0-9-]+:\d{12}:parameter/pmbot/live(/.*)?$")
POLICY_SERVICES = frozenset({"s3", "ssmmessages"})
S3_READS = frozenset({"s3:getobject", "s3:listbucket"})
S3_WRITES = frozenset({"s3:putobject", "s3:abortmultipartupload"})
# Key prefixes under sports/ (SPORTS_S3_PREFIX) each plane's role may PutObject to. Must equal `local.planes`
# in iam.tf (test_plane_prefixes_equal_iam_tf parses both). pmbot-task-live has none until EP-033 adds it.
# Cross-plane overlaps are listed in ci/test_plan_guard.py ALLOWED_OVERLAPS. paper's nba/injury_parsed/ is the
# inline maker path's parse cache (data/nba/live.py -> ingest._cached_pdf_rows); CHORE-015 (EP-031-T11) drops it.
PLANE_WRITE_PREFIXES: dict[str, tuple[str, ...]] = {
    "collect": ("recorder/", "collectors/"),
    "model": ("nba/", "nhl/", "predictions/", "recorder/nba_injury/"),
    "paper": ("live/maker/journal.paper.", "live/prices/", "live/tape/", "nba/injury_parsed/"),
    "research": ("experiments/", "panel/", "gamma/", "prices/", "pretrades/", "tape/", "hist/", "nba/", "nhl/",
                 "nfl/", "ncaab/", "collectors/xvenue/", "ledger.jsonl"),
}
FORBIDDEN_PREFIXES = ("LIVE_ENABLE_", "POLYMARKET_")
LIVE_TRADING = "LIVE_TRADING"
PAPER = "0"
EXIT_OK, EXIT_REFUSED, EXIT_UNREADABLE = 0, 1, 2


class PlanUnreadable(ValueError):
    """The input is not a usable `terraform show -json` plan."""


def load_plan(path: Path) -> dict[str, Any]:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PlanUnreadable(f"{path}: {exc}") from exc
    if not isinstance(plan, dict) or "format_version" not in plan:
        raise PlanUnreadable(f"{path}: not a `terraform show -json` plan (no format_version)")
    return plan


def managed_changes(plan: dict[str, Any]) -> list[dict[str, Any]]:
    """The managed-resource changes; data-source reads are skipped. Malformed entries are unreadable."""
    changes = plan.get("resource_changes", [])
    if not isinstance(changes, list):
        raise PlanUnreadable("resource_changes is not a list")
    out: list[dict[str, Any]] = []
    for entry in changes:
        change = entry.get("change") if isinstance(entry, dict) else None
        if not isinstance(change, dict) or not isinstance(change.get("actions"), list):
            raise PlanUnreadable(f"malformed resource change: {entry!r:.200}")
        if entry.get("mode", "managed") == "managed":
            out.append(entry)
    return out


def _actions(entry: dict[str, Any]) -> list[str]:
    return [str(action) for action in entry["change"]["actions"]]


def destructive_refusals(changes: list[dict[str, Any]]) -> list[str]:
    out: list[str] = []
    for entry in changes:
        actions = _actions(entry)
        if entry.get("type") in GUARDED_TYPES and "delete" in actions:
            out.append(f"`{entry.get('address')}` ({'/'.join(actions)}): {entry.get('type')} is guarded "
                       "against delete and replace")
    return out


def cd_role_refusals(changes: list[dict[str, Any]]) -> list[str]:
    out: list[str] = []
    for entry in changes:
        actions = _actions(entry)
        if CD_ROLE_ADDRESS.match(str(entry.get("address", ""))) and set(actions) - INERT_ACTIONS:
            out.append(f"`{entry.get('address')}` ({'/'.join(actions)}): GitHub OIDC roles and policies are "
                       "owner-applied, never by CD")
    return out


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _parse_statements(raw: Any) -> tuple[list[dict[str, Any]], str]:
    """(statements, "") for a policy document string, or ([], why it cannot be read)."""
    if not isinstance(raw, str):
        return [], "the policy document is unknown at plan time, so its scope cannot be checked"
    try:
        document = json.loads(raw)
    except json.JSONDecodeError:
        return [], "the policy document is not JSON"
    statements = document.get("Statement") if isinstance(document, dict) else None
    statements = _as_list(statements)
    if not statements or not all(isinstance(item, dict) for item in statements):
        return [], "the policy document has no readable Statement list"
    return statements, ""


def _write_target_ok(resource: str, prefixes: tuple[str, ...]) -> bool:
    """An object ARN whose key starts (literally, before any wildcard) with one of the plane's prefixes."""
    if not resource.startswith(SPORTS_ARN):
        return False
    key = resource[len(SPORTS_ARN):]
    return any(key.startswith(prefix) for prefix in prefixes)


def _in_data_bucket(resource: str) -> bool:
    return resource == BUCKET_ARN or resource.startswith(BUCKET_ARN + "/")


def _has_delete_deny(statements: list[dict[str, Any]]) -> bool:
    """An unconditional Deny of s3:Delete* that covers the bucket and its objects."""
    need = {BUCKET_ARN, f"{BUCKET_ARN}/*"}
    for item in statements:
        if item.get("Effect") != "Deny" or item.get("Condition"):
            continue
        actions = {str(action).lower() for action in _as_list(item.get("Action"))}
        if actions & {"s3:delete*", "s3:*", "*"} and need <= {str(r) for r in _as_list(item.get("Resource"))}:
            return True
    return False


def scope_problems(statements: list[dict[str, Any]], role: str, prefixes: tuple[str, ...]) -> list[str]:
    """What is wrong with a task role's policy statements (empty = within the plane)."""
    problems: list[str] = []
    for index, item in enumerate(statements):
        where = f"statement {item.get('Sid', index)}"
        if item.get("Effect") not in ("Allow", "Deny"):
            problems.append(f"{where}: Effect must be Allow or Deny")
            continue
        if item["Effect"] == "Deny":
            continue
        if "NotAction" in item or "NotResource" in item:
            problems.append(f"{where}: NotAction/NotResource cannot be scope-checked")
            continue
        actions = [str(action) for action in _as_list(item.get("Action"))]
        resources = [str(resource) for resource in _as_list(item.get("Resource"))]
        writes: list[str] = []
        for action in actions:
            low = action.lower()
            service = low.split(":", 1)[0]
            if low == "*" or low.endswith(":*"):
                problems.append(f"{where}: wildcard action {action}")
            elif service == "s3":
                if low in S3_WRITES:
                    writes.append(action)
                elif low not in S3_READS:
                    problems.append(f"{where}: {action} is not one of the S3 actions a task role may hold "
                                    f"({sorted(S3_READS | S3_WRITES)})")
            elif service == "ssm":
                if role != LIVE_ROLE:
                    problems.append(f"{where}: {action} (SSM parameter access is only for {LIVE_ROLE})")
                elif not resources or not all(SSM_LIVE.match(r) for r in resources):
                    problems.append(f"{where}: {action} outside /pmbot/live/")
            elif service not in POLICY_SERVICES:
                problems.append(f"{where}: {action} (service {service!r} is not allowed on a task role)")
        if any(a.lower().startswith("s3:") for a in actions):
            outside = [r for r in resources if not _in_data_bucket(r)]
            if outside:
                problems.append(f"{where}: S3 resource(s) outside the data bucket: {outside}")
        if writes:
            stray = [r for r in resources if not _write_target_ok(r, prefixes)] or ([] if resources else ["(none)"])
            if stray:
                problems.append(f"{where}: write action(s) {writes} on {stray}, outside the plane's prefixes "
                                f"{list(prefixes)}")
    if not _has_delete_deny(statements):
        problems.append("no unconditional Deny of s3:Delete* on the bucket and its objects")
    return list(dict.fromkeys(problems))


def _after(entry: dict[str, Any]) -> dict[str, Any]:
    after = entry["change"].get("after")
    return after if isinstance(after, dict) else {}


def _policy_unknown(entry: dict[str, Any]) -> bool:
    unknown = entry["change"].get("after_unknown")
    return isinstance(unknown, dict) and bool(unknown.get("policy"))


def _legacy_problems(entry: dict[str, Any], statements: list[dict[str, Any]]) -> list[str]:
    """The legacy pmbot-task policy keeps its bucket-wide write for rollback; it may only lose statements."""
    before = entry["change"].get("before")
    if not isinstance(before, dict):
        return []                                    # a create (a rebuild from an empty state): reviewed in the PR
    old, why = _parse_statements(before.get("policy"))
    if why:
        return [f"the legacy policy's previous document is unreadable ({why})"]
    added = [item.get("Sid", "?") for item in statements if item not in old]
    return [f"the legacy {LEGACY_ROLE} policy may only lose statements (rollback revisions still use it); "
            f"changed or added: {added}"] if added else []


def role_policy_refusals(changes: list[dict[str, Any]]) -> list[str]:
    """Task-role inline policies this plan creates or updates must stay inside their plane (EP-031).
    The legacy pmbot-task policy is allowed to shrink only; managed policies cannot be attached to task roles."""
    out: list[str] = []
    for entry in changes:
        actions = _actions(entry)
        if not {"create", "update"} & set(actions):
            continue
        address, label = str(entry.get("address", "")), "/".join(actions)
        role = _after(entry).get("role")
        role = role if isinstance(role, str) else ""
        if entry.get("type") == ATTACHMENT_TYPE:
            if TASK_ROLE.match(role) and role != EXECUTION_ROLE:
                out.append(f"`{address}` ({label}): a managed policy attached to {role}; task roles take "
                           "inline policies only")
            continue
        if entry.get("type") != POLICY_TYPE:
            continue
        plane = PLANE_ROLE.match(address)
        if plane:
            wanted = f"pmbot-task-{plane['plane']}"
            if role and role != wanted:
                out.append(f"`{address}` ({label}): attached to {role}, not {wanted}")
                continue
            role = wanted
        elif address == LEGACY_POLICY_ADDRESS:
            role = LEGACY_ROLE
        elif not TASK_ROLE.match(role) or role == EXECUTION_ROLE:
            continue                                  # not a task role's policy (scheduler, github_*, ...)
        if _policy_unknown(entry):
            statements, why = [], "the policy document is unknown at plan time, so its scope cannot be checked"
        else:
            statements, why = _parse_statements(_after(entry).get("policy"))
        if why:
            out.append(f"`{address}` ({label}): {why}")
            continue
        if role == LEGACY_ROLE:
            problems = _legacy_problems(entry, statements)
        else:
            prefixes = PLANE_WRITE_PREFIXES.get(role.removeprefix("pmbot-task-"), ())
            problems = scope_problems(statements, role, prefixes)
        out += [f"`{address}` ({label}): {problem}" for problem in problems]
    return out


def _lower_keys(value: Any, clashes: list[str]) -> Any:
    """`value` with every dict key lower-cased, recursively; keys that differ only in case go to
    `clashes` (which of them ECS reads is unknown, so the caller refuses)."""
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, item in value.items():
            low = str(key).lower()
            if low in out:
                clashes.append(low)
            out[low] = _lower_keys(item, clashes)
        return out
    if isinstance(value, list):
        return [_lower_keys(item, clashes) for item in value]
    return value


def container_violations(containers: Any, where: str) -> list[str]:
    """Live-trading settings in a parsed container_definitions list (same rules as ecs_deploy.py).
    Key case and name padding are ignored; a non-object entry, a non-list setting or keys differing
    only in case are violations too."""
    if not isinstance(containers, list):
        return [f"{where}: container_definitions is not a list"]
    clashes: list[str] = []
    containers = _lower_keys(containers, clashes)
    found = ([f"{where}: keys differ only in case ({', '.join(sorted(set(clashes)))}), "
              "so paper only cannot be checked"] if clashes else [])
    for container in containers:
        if not isinstance(container, dict):
            found.append(f"{where}: a container definition is not an object")
            continue
        name = f"{where}/{container.get('name', '?')}"
        for kind in ("environment", "secrets"):
            entries = container.get(kind) or []
            if not isinstance(entries, list):
                found.append(f"{name}: {kind} is not a list")
                continue
            for entry in entries:
                if not isinstance(entry, dict):
                    found.append(f"{name}: {kind} entry {entry!r:.80} is not an object")
                    continue
                key = str(entry.get("name", "")).strip().upper()
                if kind == "secrets":
                    if key.startswith(FORBIDDEN_PREFIXES) or key == LIVE_TRADING:
                        found.append(f"{name}: secret {key}")
                elif key.startswith(FORBIDDEN_PREFIXES):
                    found.append(f"{name}: environment {key}")
                elif key == LIVE_TRADING and entry.get("value") != PAPER:
                    found.append(f"{name}: environment LIVE_TRADING={entry.get('value')!r} "
                                 f"(only {PAPER!r} is allowed)")
        if container.get("environmentfiles"):
            found.append(f"{name}: environmentFiles (contents cannot be checked)")
    return found


def paper_refusals(changes: list[dict[str, Any]]) -> list[str]:
    out: list[str] = []
    for entry in task_definition_entries(changes):
        where = f"`{entry.get('address')}`"
        after = entry["change"].get("after")
        unknown = entry["change"].get("after_unknown")
        raw = after.get("container_definitions") if isinstance(after, dict) else None
        if (isinstance(unknown, dict) and unknown.get("container_definitions")) or not isinstance(raw, str):
            out.append(f"{where}: container_definitions unknown at plan time, so paper only cannot be checked")
            continue
        try:
            containers = json.loads(raw)
        except json.JSONDecodeError:
            out.append(f"{where}: container_definitions is not JSON")
            continue
        out += container_violations(containers, where)
    return out


def task_definition_entries(changes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Task definitions this plan creates or updates (a replace is delete + create)."""
    return [entry for entry in changes
            if entry.get("type") == TASK_DEFINITION and {"create", "update"} & set(_actions(entry))]


def task_definition_changes(changes: list[dict[str, Any]]) -> list[str]:
    return [str(entry.get("address")) for entry in task_definition_entries(changes)]


def evaluate(plan: dict[str, Any]) -> tuple[list[str], list[str]]:
    """(refusals, notes). Notes are the task definitions whose new revision only pmbot-deploy rolls out."""
    changes = managed_changes(plan)
    refusals = ["the plan is marked errored"] if plan.get("errored") else []
    refusals += (destructive_refusals(changes) + cd_role_refusals(changes) + role_policy_refusals(changes)
                 + paper_refusals(changes))
    return refusals, task_definition_changes(changes)


def counts(changes: list[dict[str, Any]]) -> dict[str, int]:
    out = {"create": 0, "update": 0, "replace": 0, "delete": 0}
    for entry in changes:
        actions = _actions(entry)
        if "create" in actions and "delete" in actions:
            out["replace"] += 1
        elif actions in (["create"], ["update"], ["delete"]):
            out[actions[0]] += 1
    return out


def render(refusals: list[str], notes: list[str], tally: dict[str, int]) -> str:
    verdict = "REFUSED: nothing will be applied" if refusals else "OK to apply"
    lines = [f"#### plan_guard: {verdict}", "",
             "create {create}, update {update}, replace {replace}, delete {delete}".format(**tally)]
    if refusals:
        lines += ["", "Refused (the owner applies by hand from a saved plan, products/pmbot/README.md):",
                  *[f"- {item}" for item in refusals]]
    if notes:
        lines += ["", "Task definitions change. The services keep their deployed revision until "
                      "polymarket-bot's pmbot-deploy runs: dispatch it with the image tag running now.",
                  *[f"- `{address}`" for address in notes]]
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Refuse unsafe products/pmbot plans before auto-apply (CH-008).")
    ap.add_argument("plan_json", type=Path, help="output of `terraform show -json <planfile>`")
    args = ap.parse_args(argv)
    try:
        plan = load_plan(args.plan_json)
        refusals, notes = evaluate(plan)
        tally = counts(managed_changes(plan))
    except PlanUnreadable as exc:
        print(f"#### plan_guard: REFUSED (unreadable plan)\n\n- {exc}")
        return EXIT_UNREADABLE
    print(render(refusals, notes, tally), end="")
    return EXIT_REFUSED if refusals else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
