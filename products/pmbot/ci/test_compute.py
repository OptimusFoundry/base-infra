"""Static checks of compute.tf and variables.tf (polymarket-bot EP-032-T9, branch ep-032-compute). Stdlib only:

    python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v    # from the repo root

Pins the host: t4g.xlarge, unlimited CPU credits, ECS_RESERVED_MEMORY=512, one /data/<family> dir per family created
owned by uid 10001, and nothing that would replace the running instance. Each guard is mutation-checked: change the
pinned text in compute.tf or variables.tf and the matching test fails."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import plan_guard  # noqa: E402
from test_plan_guard import plan, rc  # noqa: E402

PMBOT = Path(__file__).resolve().parents[1]
# polymarket-bot strategy-layer/sports/ops/sizing.py FAMILIES plus the EP-034 research slot. The twin of
# test_services_sizes.py's list; the host_path test below reads services.tf, so the two cannot drift apart.
DATA_FAMILIES = ["recorder", "maker-paper", "maker-live", "ingame-capture", "xvenue-poller", "rewards-poll",
                 "daily-ingest", "predictor", "research"]
LAUNCH_TEMPLATE = "aws_launch_template.instance"
ASG = "aws_autoscaling_group.pmbot"


def read(name: str) -> str:
    return (PMBOT / name).read_text(encoding="utf-8")


def code(name: str) -> str:
    """The file without whole-line comments."""
    return "\n".join(line for line in read(name).splitlines() if not line.strip().startswith("#"))


def resource(text: str, kind: str, name: str) -> str:
    match = re.search(rf'^resource "{kind}" "{name}" \{{\n(.*?)^\}}\n', text, re.M | re.S)
    assert match is not None, f"{kind}.{name} not found"
    return match.group(1)


def launch_template() -> str:
    return resource(code("compute.tf"), "aws_launch_template", "instance")


def user_data() -> str:
    match = re.search(r"user_data\s*=\s*base64encode\(<<-EOT\n(.*?)^\s*EOT\n", launch_template(), re.M | re.S)
    assert match is not None, "user_data heredoc not found"
    return match.group(1)


def ecs_config() -> list[str]:
    match = re.search(r"<<'ECSCONFIG'\n(.*?)^\s*ECSCONFIG\n", user_data(), re.M | re.S)
    assert match is not None, "ecs.config heredoc not found"
    return [line.strip() for line in match.group(1).splitlines() if line.strip()]


class InstanceType(unittest.TestCase):
    def test_the_default_is_a_t4g_xlarge(self) -> None:
        """Mutation-checked: put t4g.large back and this fails."""
        match = re.search(r'variable "instance_type" \{(.*?)^\}', code("variables.tf"), re.M | re.S)
        self.assertIsNotNone(match)
        self.assertRegex(match.group(1), r'default\s+=\s+"t4g\.xlarge"')  # type: ignore[union-attr]

    def test_the_launch_template_takes_the_type_from_the_variable(self) -> None:
        self.assertRegex(launch_template(), r"instance_type\s+=\s+var\.instance_type\n")

    def test_no_other_file_hard_codes_an_instance_type(self) -> None:
        for path in sorted(PMBOT.glob("*.tf")):
            if path.name == "variables.tf":
                continue
            self.assertNotRegex(code(path.name), r'"t4g\.[a-z0-9]+"', path.name)


class Credits(unittest.TestCase):
    def test_cpu_credits_are_pinned_to_unlimited(self) -> None:
        """Mutation-checked: `standard`, or removing the block, fails."""
        self.assertRegex(launch_template(), r'credit_specification \{\n\s+cpu_credits\s+=\s+"unlimited"\n\s+\}')
        self.assertNotIn('"standard"', launch_template())


class EcsAgent(unittest.TestCase):
    def test_ecs_reserved_memory_is_512_inside_the_ecs_config_heredoc(self) -> None:
        """Mutation-checked: remove the line, change the number, or move it out of the heredoc and this fails."""
        self.assertEqual([line for line in ecs_config() if line.startswith("ECS_RESERVED_MEMORY")],
                         ["ECS_RESERVED_MEMORY=512"])

    def test_the_existing_agent_settings_are_kept(self) -> None:
        keys = [line.split("=", 1)[0] for line in ecs_config()]
        self.assertEqual(keys, ["ECS_CLUSTER", "ECS_INSTANCE_ATTRIBUTES", "ECS_ENABLE_TASK_IAM_ROLE",
                                "ECS_CONTAINER_STOP_TIMEOUT", "ECS_RESERVED_MEMORY"])
        self.assertIn("ECS_CONTAINER_STOP_TIMEOUT=120s", ecs_config())


class DataDirs(unittest.TestCase):
    def test_the_family_list_is_the_nine_dirs(self) -> None:
        match = re.search(r"^  data_families = \[\n(.*?)^  \]\n", code("compute.tf"), re.M | re.S)
        self.assertIsNotNone(match)
        names = re.findall(r'^\s+"([a-z-]+)",$', match.group(1), re.M)  # type: ignore[union-attr]
        self.assertEqual(names, DATA_FAMILIES)
        self.assertEqual(len(set(names)), 9)

    def test_user_data_creates_and_chowns_every_family_dir_and_still_the_root(self) -> None:
        """Mutation-checked: drop the loop, the chown, or the join over the list and this fails."""
        text = user_data()
        self.assertIn('for family in ${join(" ", local.data_families)}; do', text)
        self.assertIn('mkdir -p "/data/$family"', text)
        self.assertIn('chown 10001:10001 "/data/$family"', text)
        self.assertIn("mkdir -p /data\n", text)
        self.assertIn("chown 10001:10001 /data\n", text)
        self.assertLess(text.index("mkdir -p /data\n"), text.index("for family in"))

    def test_every_per_family_host_path_in_services_tf_is_created(self) -> None:
        """Vacuous while services.tf still mounts bare /data (this branch); it bites once the services PR is on main:
        a host_path /data/<family> that user data does not create would be root-owned and unwritable."""
        used = re.findall(r'host_path\s+=\s+"/data/([a-z-]+)"', code("services.tf"))
        self.assertLessEqual(set(used), set(DATA_FAMILIES))


class NothingReplacesTheInstance(unittest.TestCase):
    def test_the_autoscaling_group_has_no_instance_refresh(self) -> None:
        """A plan must never replace the running instance: replacement is the runbook's flush-then-terminate step."""
        asg = resource(code("compute.tf"), "aws_autoscaling_group", "pmbot")
        self.assertNotRegex(asg, r"instance_refresh\s*\{")
        self.assertRegex(asg, r"version\s+=\s+aws_launch_template\.instance\.latest_version")

    def test_the_launch_template_keeps_its_name_prefix_and_create_before_destroy(self) -> None:
        """Renaming the prefix would replace the template; the update must stay a new version."""
        text = launch_template()
        self.assertRegex(text, r'name_prefix\s+=\s+"pmbot-ecs-"')
        self.assertRegex(text, r"create_before_destroy\s+=\s+true")
        self.assertRegex(text, r"update_default_version\s+=\s+true")

    def test_the_expected_plan_is_two_in_place_updates_and_the_guard_passes(self) -> None:
        expected = plan(rc(LAUNCH_TEMPLATE, ["update"]), rc(ASG, ["update"]))
        self.assertEqual(plan_guard.evaluate(expected), ([], []))
        self.assertEqual(plan_guard.counts(plan_guard.managed_changes(expected)),
                         {"create": 0, "update": 2, "replace": 0, "delete": 0})

    def test_the_guard_would_refuse_a_replacement_of_either(self) -> None:
        for address in (LAUNCH_TEMPLATE, ASG):
            with self.subTest(address=address):
                refusals, _ = plan_guard.evaluate(plan(rc(address, ["delete", "create"])))
                self.assertEqual(len(refusals), 1)
                self.assertIn("guarded against delete and replace", refusals[0])


if __name__ == "__main__":
    unittest.main()
