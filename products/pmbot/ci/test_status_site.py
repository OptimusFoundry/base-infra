"""Static checks of the status site (polymarket-bot CH-009, AC6): status.tf and the CH-009 statements of
github-cd.tf. Stdlib only, like the rest of ci/:

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v    # from the repo root
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

PMBOT = Path(__file__).resolve().parents[1]


def read(name: str) -> str:
    return (PMBOT / name).read_text(encoding="utf-8")


def balanced(text: str, open_at: int) -> str:
    """text[open_at:] up to the brace that closes the one at open_at (`${...}` interpolations balance too)."""
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    raise AssertionError(f"unbalanced block at {open_at}")


def block(text: str, header: str) -> str:
    start = text.index(header)
    return balanced(text, text.index("{", start + len(header) - 1))


def statement(text: str, sid: str) -> str:
    """The `{ ... Sid = "<sid>" ... }` object of a jsonencode()d policy."""
    at = re.search(rf'Sid\s+=\s+"{sid}"', text)
    assert at is not None, f"statement {sid} not found"
    depth = 0
    for i in range(at.start(), -1, -1):
        if text[i] == "}":
            depth += 1
        elif text[i] == "{":
            if depth == 0:
                return balanced(text, i)
            depth -= 1
    raise AssertionError(f"no object around {sid}")


class SiteBucket(unittest.TestCase):
    def test_public_access_is_blocked_four_ways(self) -> None:
        body = block(read("status.tf"), 'resource "aws_s3_bucket_public_access_block" "site"')
        for flag in ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"):
            self.assertRegex(body, rf"{flag}\s+=\s+true")

    def test_only_cloudfront_reads_and_only_through_this_distribution(self) -> None:
        """Mutation-checked: drop the AWS:SourceArn condition, or add a `Principal = "*"` Allow, and this fails."""
        policy = block(read("status.tf"), 'resource "aws_s3_bucket_policy" "site"')
        self.assertEqual(len(re.findall(r'Effect\s+=\s+"Allow"', policy)), 1)
        allow = statement(policy, "CloudFrontReadsThroughOac")
        self.assertRegex(allow, r'Principal\s+=\s+\{\s*Service\s+=\s+"cloudfront\.amazonaws\.com"\s*\}')
        self.assertRegex(allow, r'Action\s+=\s+"s3:GetObject"')
        self.assertRegex(allow, r'"AWS:SourceArn"\s+=\s+aws_cloudfront_distribution\.site\.arn')
        deny = statement(policy, "TlsOnly")
        self.assertRegex(deny, r'Effect\s+=\s+"Deny"')
        self.assertRegex(deny, r'"aws:SecureTransport"\s+=\s+"false"')
        ownership = block(read("status.tf"), 'resource "aws_s3_bucket_ownership_controls" "site"')
        self.assertRegex(ownership, r'object_ownership\s+=\s+"BucketOwnerEnforced"')

    def test_the_distribution_serves_https_from_the_bucket_through_oac(self) -> None:
        dist = block(read("status.tf"), 'resource "aws_cloudfront_distribution" "site"')
        self.assertRegex(dist, r"origin_access_control_id\s+=\s+aws_cloudfront_origin_access_control\.site\.id")
        self.assertEqual(len(re.findall(r'viewer_protocol_policy\s+=\s+"redirect-to-https"', dist)), 2)
        self.assertRegex(dist, r"aliases\s+=\s+\[local\.site_domain\]")
        self.assertRegex(dist, r"acm_certificate_arn\s+=\s+data\.terraform_remote_state\.platform\.outputs\.acm_certificate_arn")
        at = re.search(r'path_pattern\s+=\s+"/status\.json"', dist)
        self.assertIsNotNone(at)
        self.assertRegex(dist[at.end():at.end() + 600], r"cache_policy_id\s+=\s+local\.cache_policy_disabled")  # type: ignore[union-attr]
        self.assertNotIn("custom_origin_config", dist)                  # one origin only: no API path


class StatusTask(unittest.TestCase):
    def test_the_task_role_may_write_only_status_json(self) -> None:
        """AC6. Mutation-checked: widen the Resource to `${aws_s3_bucket.site.arn}/*`, add s3:DeleteObject, or point
        it at var.data_bucket, and this fails."""
        policy = block(read("status.tf"), 'resource "aws_iam_role_policy" "status"')
        self.assertEqual(re.findall(r'"(s3:[A-Za-z*]+)"', policy), ["s3:PutObject"])
        put = statement(policy, "PublishStatusJsonOnly")
        self.assertRegex(put, r'Resource\s+=\s+"\$\{aws_s3_bucket\.site\.arn\}/status\.json"')
        self.assertNotIn("data_bucket", policy)
        self.assertNotIn('"*"', put)
        services = re.findall(r'"([a-z0-9]+):[A-Za-z*]+"', policy)
        self.assertEqual(set(services), {"s3", "ssmmessages"})

    def test_the_role_is_not_a_plane_task_role(self) -> None:
        """EP-031's plan_guard scope-checks pmbot-task(-*) roles against the data bucket; this role is not one."""
        role = block(read("status.tf"), 'resource "aws_iam_role" "status"')
        name = re.search(r'name\s+=\s+"([^"]+)"', role)
        self.assertIsNotNone(name)
        self.assertEqual(name.group(1), "pmbot-status")  # type: ignore[union-attr]
        self.assertIsNone(re.fullmatch(r"pmbot-task(-[a-z0-9-]+)?", name.group(1)))  # type: ignore[union-attr]

    def test_the_task_reads_data_read_only_and_never_syncs_it(self) -> None:
        """Mutation-checked: flip readOnly to false, or SPORTS_S3 to "rw", and this fails."""
        text = read("status.tf")
        task = block(text, 'resource "aws_ecs_task_definition" "status"')
        self.assertRegex(task, r"readOnly\s+=\s+true")
        self.assertNotRegex(task, r"readOnly\s+=\s+false")
        self.assertRegex(task, r'command\s+=\s+\["python", "-m", "sports\.ops\.status_page", "loop"\]')
        self.assertRegex(task, r"task_role_arn\s+=\s+aws_iam_role\.status\.arn")
        self.assertIn(":${var.image_tag}-collect\"", task)
        at = re.search(r"status_env\s+=\s+\{", text)
        self.assertIsNotNone(at)
        env = balanced(text, at.end() - 1)  # type: ignore[union-attr]
        self.assertRegex(env, r'SPORTS_S3\s+=\s+"off"')
        self.assertRegex(env, r"STATUS_SITE_BUCKET\s+=\s+local\.site_bucket")
        for forbidden in ("LIVE_", "POLYMARKET_", "secrets"):
            self.assertNotIn(forbidden, task + env)

    def test_the_service_starts_parked_and_ignores_deploys(self) -> None:
        svc = block(read("status.tf"), 'resource "aws_ecs_service" "status"')
        self.assertRegex(svc, r"desired_count\s+=\s+0")
        self.assertRegex(svc, r"ignore_changes\s+=\s+\[desired_count, task_definition\]")
        self.assertRegex(svc, r'name\s+=\s+"pmbot-status"')


class CdRoles(unittest.TestCase):
    def test_the_deploy_role_uploads_the_page_but_never_status_json(self) -> None:
        """Mutation-checked: make UploadTheSite's Resource `${aws_s3_bucket.site.arn}/*` (or add status.json) and
        this fails."""
        text = read("github-cd.tf")
        upload = statement(text, "UploadTheSite")
        resources = re.findall(r'"\$\{aws_s3_bucket\.site\.arn\}(/[^"]*)"', upload)
        self.assertEqual(sorted(resources), ["/assets/*", "/index.html", "/scoreboard.json"])
        self.assertRegex(upload, r'Action\s+=\s+\["s3:PutObject", "s3:DeleteObject"\]')
        self.assertRegex(statement(text, "ListTheSiteBucket"), r"Resource\s+=\s+aws_s3_bucket\.site\.arn")
        self.assertRegex(statement(text, "InvalidateTheSite"), r"Resource\s+=\s+aws_cloudfront_distribution\.site\.arn")
        passrole = statement(text, "PassTheStatusTaskRole")
        self.assertRegex(passrole, r"Resource\s+=\s+aws_iam_role\.status\.arn")
        self.assertRegex(passrole, r'"iam:PassedToService"\s+=\s+"ecs-tasks\.amazonaws\.com"')

    def test_the_plan_role_only_reads_the_site(self) -> None:
        text = read("github-cd.tf")
        reads = text[text.index("terraform_read_statements = ["):text.index("terraform_write_statements = [")]
        for sid in ("ReadTheSiteBucket", "ReadCloudFront"):
            actions = re.findall(r'"([a-z0-9]+:[A-Za-z*]+)"', statement(reads, sid))
            self.assertTrue(actions)
            self.assertTrue(all(a.split(":")[1].startswith(("Get", "List")) for a in actions), actions)

    def test_the_apply_role_writes_only_the_site_bucket_and_pmbot_tagged_distributions(self) -> None:
        text = read("github-cd.tf")
        writes = text[text.index("terraform_write_statements = ["):]
        bucket = statement(writes, "ManageTheSiteBucket")
        self.assertIn('"arn:aws:s3:::${local.site_bucket}"', bucket)
        self.assertIn('"arn:aws:s3:::${local.site_bucket}/*"', bucket)
        dist = statement(writes, "ManageThePmbotDistribution")
        self.assertRegex(dist, r'"aws:ResourceTag/Product"\s+=\s+var\.product')
        for create in ("cloudfront:CreateDistribution", "cloudfront:CreateOriginAccessControl"):
            self.assertNotIn(create, dist)                             # creates are owner-applied


if __name__ == "__main__":
    unittest.main()
