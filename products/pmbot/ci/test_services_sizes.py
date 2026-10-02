"""Static checks of services.tf sizes, data dirs and EP-032 environment (polymarket-bot EP-032-T9, branch
ep-032-services). Stdlib only:

    python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v    # from the repo root

SIZES is the twin of polymarket-bot strategy-layer/sports/ops/sizing.py SIZES (its `check-tf` command diffs the real
file against that module). Each guard is mutation-checked: edit services.tf the way the test name says and it fails."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_services_maps import SCHEDULED, task_names  # noqa: E402

PMBOT = Path(__file__).resolve().parents[1]
SIZES = {   # (cpu, memory_reservation, memory) in CPU units and MiB: the plan's R8 table
    "maker-live": (512, 1024, 2048),
    "maker-paper": (512, 1024, 2048),
    "predictor": (1024, 2048, 4096),
    "recorder": (256, 512, 1024),
    "ingame-capture": (128, 960, 1472),
    "xvenue-poller": (128, 256, 512),
    "rewards-poll": (128, 320, 512),
    "daily-ingest": (512, 1536, 4096),
}
RESEARCH_SLOT = (512, 4096)
HOST_CPU = 4096
HOST_MEMORY = 15_200    # t4g.xlarge: about 15,700 MiB registered minus ECS_RESERVED_MEMORY=512 (an estimate)
DATA_DIRS = ["recorder", "maker-paper", "maker-live", "ingame-capture", "xvenue-poller", "rewards-poll",
             "daily-ingest", "predictor", "research"]    # twin of test_compute.py DATA_FAMILIES (compute.tf)
PRUNE = {
    "recorder": "recorder/=7",
    "ingame-capture": "collectors/=7", "xvenue-poller": "collectors/=7", "rewards-poll": "collectors/=7",
    "predictor": "predictions/=3", "maker-paper": "predictions/=3",
}
SIZE_LINE = re.compile(r'^    "?(?P<name>[a-z][a-z-]*)"?\s+=\s+\{ cpu = (?P<cpu>\d+), memory_reservation = (?P<res>\d+), '
                       r"memory = (?P<mem>\d+) \}$")


def code() -> str:
    """services.tf without whole-line comments."""
    text = (PMBOT / "services.tf").read_text(encoding="utf-8")
    return "\n".join(line for line in text.splitlines() if not line.strip().startswith("#")) + "\n"


def block(text: str, indent: int, name: str) -> str:
    pad = " " * indent
    match = re.search(rf"^{pad}{name} = \{{\n(.*?)^{pad}\}}\n", text, re.M | re.S)
    assert match is not None, f"{name} not found"
    return match.group(1)


def size_table() -> dict[str, tuple[int, int, int]]:
    table = {}
    for line in block(code(), 2, "task_sizes").splitlines():
        match = SIZE_LINE.match(line)
        assert match is not None, f"task_sizes: unreadable line {line!r}"
        table[match["name"]] = (int(match["cpu"]), int(match["res"]), int(match["mem"]))
    return table


def family_block(name: str) -> str:
    """The `<name> = { ... }` entry of local.services, or local.daily_ingest / local.predictor."""
    text = code()
    if name in SCHEDULED:
        return block(text, 2, name.replace("-", "_"))
    return block(block(text, 2, "services"), 4, name)


class Sizes(unittest.TestCase):
    def test_task_sizes_is_the_chosen_table(self) -> None:
        """Mutation-checked: change one number in local.task_sizes and this fails."""
        self.assertEqual(size_table(), SIZES)

    def test_the_research_slot_reserves_nothing(self) -> None:
        """Mutation-checked: a memory_reservation on the slot, or cpu 1024, or memory != 4096 fails."""
        lines = re.findall(r"^  research_slot\b.*$", code(), re.M)
        self.assertEqual(lines, ["  research_slot = { cpu = 512, memory = 4096 }"])
        self.assertNotIn("memory_reservation", lines[0])

    def test_task_sizes_cover_exactly_the_tasks_plus_maker_live(self) -> None:
        self.assertEqual(set(size_table()), task_names() | {"maker-live"})
        self.assertEqual(set(size_table()), set(SIZES))

    def test_every_task_takes_the_size_of_its_own_row(self) -> None:
        """Mutation-checked: point one family at another's row and this fails."""
        for name in sorted(task_names()):
            with self.subTest(task=name):
                self.assertIn(f'      size      = local.task_sizes["{name}"]\n'
                              if name not in SCHEDULED else f'    size      = local.task_sizes["{name}"]\n',
                              family_block(name))

    def test_no_task_keeps_a_literal_size(self) -> None:
        text = code().replace(block(code(), 2, "task_sizes"), "")
        text = re.sub(r"^  research_slot = .*\n", "", text, flags=re.M)
        self.assertEqual(re.findall(r"^\s+(?:cpu|memory_reservation|memory)\s+=\s+\d+\s*$", text, re.M), [])

    def test_the_container_definitions_read_the_size(self) -> None:
        text = code()
        for line in ("      cpu               = task.size.cpu\n", "      memoryReservation = task.size.memory_reservation\n",
                     "      memory            = task.size.memory\n"):
            self.assertTrue(line in text, line)
        self.assertNotRegex(text, r"task\.(cpu|memory)\b")


class HostFit(unittest.TestCase):
    def test_every_reservation_with_maker_live_plus_the_slot_fits_the_host(self) -> None:
        table = size_table()
        memory = sum(res for _, res, _ in table.values())
        cpu = sum(cpu for cpu, _, _ in table.values())
        self.assertEqual((memory, cpu), (7_680, 3_200))
        slot_cpu, slot_memory = RESEARCH_SLOT
        self.assertLessEqual(memory + slot_memory, HOST_MEMORY - 1_024)      # a GiB to spare with maker-live
        self.assertLessEqual(cpu + slot_cpu, HOST_CPU)

    def test_no_reservation_exceeds_its_hard_cap(self) -> None:
        for name, (_, res, mem) in size_table().items():
            self.assertLessEqual(res, mem, name)


class DataDirs(unittest.TestCase):
    def test_every_task_mounts_its_own_dir_and_none_mounts_bare_data(self) -> None:
        """Mutation-checked: put `host_path = "/data"` back on one task definition and this fails."""
        text = code()
        self.assertEqual(re.findall(r'host_path\s+=\s+"([^"]+)"', text),
                         ["/data/${each.key}", "/data/daily-ingest", "/data/predictor"])
        self.assertNotRegex(text, r'host_path\s+=\s+"/data"')
        self.assertTrue('resource "aws_ecs_task_definition" "svc" {\n  for_each = local.services\n' in text)

    def test_the_dirs_are_the_task_names_and_the_rest_is_for_later(self) -> None:
        """The svc definitions use their for_each key, the two scheduled ones their literal family name; compute.tf's
        user_data creates all nine (test_compute.py), two of which (maker-live, research) have no task definition yet."""
        self.assertEqual(set(DATA_DIRS) - task_names(), {"maker-live", "research"})
        self.assertLessEqual(task_names(), set(DATA_DIRS))
        literal = {path.removeprefix("/data/") for path in re.findall(r'host_path\s+=\s+"([^"$]+)"', code())}
        self.assertEqual(literal, set(SCHEDULED))

    def test_the_container_path_and_data_root_do_not_change(self) -> None:
        text = code()
        self.assertEqual(re.findall(r'containerPath\s+=\s+"([^"]+)"', text), ["/data"])
        self.assertTrue('SPORTS_DATA_ROOT   = "/data"' in text)


class EnvironmentByFamily(unittest.TestCase):
    def test_the_prune_rule_per_family(self) -> None:
        """R7: only write-once prefixes, only the families that run a drainer, never daily-ingest."""
        for name in sorted(task_names()):
            with self.subTest(task=name):
                found = re.findall(r'SPORTS_CACHE_PRUNE\s+=\s+"([^"]+)"', family_block(name))
                self.assertEqual(found, [PRUNE[name]] if name in PRUNE else [])
        self.assertEqual(len(re.findall(r"SPORTS_CACHE_PRUNE", code())), len(PRUNE))
        for rule in PRUNE.values():
            prefix, days = rule.split("=")
            self.assertIn(prefix, ("recorder/", "collectors/", "predictions/"))
            self.assertTrue(0 < float(days) <= 365)

    def test_require_drained_is_on_daily_ingest_only(self) -> None:
        text = code()
        self.assertEqual(re.findall(r'DAILY_INGEST_REQUIRE_DRAINED\s+=\s+"([^"]*)"', text), ["1"])
        self.assertIn('DAILY_INGEST_REQUIRE_DRAINED = "1"', family_block("daily-ingest"))

    def test_no_live_or_polymarket_setting_and_paper_stays_forced(self) -> None:
        text = code()
        self.assertNotRegex(text, r"LIVE_ENABLE_|POLYMARKET_")
        self.assertEqual(re.findall(r'LIVE_TRADING\s+=\s+"([^"]*)"', text), ["0"])
        self.assertRegex(block(text, 2, "maker_env"), r'LIVE_TRADING\s+=\s+"0"')


if __name__ == "__main__":
    unittest.main()
