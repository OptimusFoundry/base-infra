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
    refusals += destructive_refusals(changes) + cd_role_refusals(changes) + paper_refusals(changes)
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
