"""Static checks of services.tf and schedule.tf against iam.tf (polymarket-bot EP-031-T9). Stdlib only:

    python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v    # from the repo root
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_plan_guard import iam_planes  # noqa: E402

PMBOT = Path(__file__).resolve().parents[1]
SCHEDULED = ("daily-ingest", "predictor")   # sports/ops/services.py SCHEDULED
PAIR = re.compile(r'^\s+"?(?P<key>[a-z][a-z-]*)"?\s+=\s+"(?P<value>[a-z]+)"$')


def read(name: str) -> str:
    return (PMBOT / name).read_text(encoding="utf-8")


def local_block(text: str, name: str) -> str:
    match = re.search(rf"^  {name} = \{{\n(.*?)^  \}}\n", text, re.M | re.S)
    assert match is not None, f"local.{name} not found"
    return match.group(1)


def string_map(name: str) -> dict[str, str]:
    """`local.<name>` of services.tf when it is a flat map of strings."""
    pairs = {}
    for line in local_block(read("services.tf"), name).splitlines():
        match = PAIR.match(line)
        assert match is not None, f"local.{name}: unreadable line {line!r}"
        pairs[match["key"]] = match["value"]
    return pairs


def task_names() -> set[str]:
    """local.all_tasks: the keys of local.services plus the two scheduled families."""
    services = re.findall(r"^    ([a-z][a-z-]*) = \{$", local_block(read("services.tf"), "services"), re.M)
    return {*services, *SCHEDULED}


class FamilyPlane(unittest.TestCase):
    def test_every_task_has_a_plane_and_the_plane_has_a_role(self) -> None:
        planes = string_map("family_plane")
        self.assertEqual(set(planes), task_names())
        self.assertEqual(len(task_names()), 7)
        self.assertLessEqual(set(planes.values()), set(iam_planes()))

    def test_the_expected_planes(self) -> None:
        self.assertEqual(string_map("family_plane"), {
            "recorder": "collect", "ingame-capture": "collect", "xvenue-poller": "collect",
            "rewards-poll": "collect", "daily-ingest": "model", "predictor": "model", "maker-paper": "paper"})

    def test_no_task_definition_still_uses_the_legacy_role(self) -> None:
        """Mutation-checked: put `aws_iam_role.task.arn` back on one family and this fails."""
        roles = re.findall(r"^\s+task_role_arn\s+=\s+(.+)$", read("services.tf"), re.M)
        self.assertEqual(len(roles), 3)
        for role in roles:
            self.assertRegex(role, r"^aws_iam_role\.plane\[local\.family_plane\[.+\]\]\.arn$")

    def test_the_queue_env_names_the_plane_in_the_same_revision(self) -> None:
        text = read("services.tf")
        self.assertIn("{ SPORTS_S3_QUEUE = local.family_plane[name] }", text)
        merge = re.search(r"merge\((local\.common_env.*?)\) :", text)
        self.assertIsNotNone(merge)
        # task.extra_env last: a family could not override the queue by accident, but a test would see it
        self.assertTrue(merge.group(1).endswith("task.extra_env"))  # type: ignore[union-attr]

    def test_the_scheduler_may_pass_the_role_the_scheduled_families_run_as(self) -> None:
        """The schedules RunTask the families' latest revisions, which run as these planes' roles."""
        planes = string_map("family_plane")
        scheduled = {planes[name] for name in SCHEDULED}
        passrole = re.search(r'Sid\s+= "PassOnlyThePmbotTaskRoles"(.*?)Condition', read("schedule.tf"), re.S)
        self.assertIsNotNone(passrole)
        passed = set(re.findall(r'aws_iam_role\.plane\["([a-z]+)"\]\.arn', passrole.group(1)))  # type: ignore[union-attr]
        self.assertEqual(passed, scheduled)


if __name__ == "__main__":
    unittest.main()
