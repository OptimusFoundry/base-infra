resource "aws_security_group" "web_dmz" {
  name        = "WebDMZSecurityGroup"
  description = "Allow port 80 and 22 access from internet"
  vpc_id      = aws_vpc.base_vpc.id
}

# Dynamic host ports (bridge-mode containers) are reachable from the ALB only.
# No SSH: the host has no key pair; Session Manager is the way in.
resource "aws_security_group_rule" "http_ingress" {
  type                     = "ingress"
  from_port                = 1024
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_sg.id
  security_group_id        = aws_security_group.web_dmz.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "allow_all_egress_to_alb" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.web_dmz.id
}

resource "aws_security_group" "alb_sg" {
  name        = "ALBSecurityGroup"
  description = "Allow port 443 access from internet"
  vpc_id      = aws_vpc.base_vpc.id
}

# The ALB is reachable only from CloudFront's origin-facing ranges. Opening it to
# 0.0.0.0/0 let a direct request set X-Product-Id itself (it routes, it is not a
# secret) and forge CloudFront-Viewer-Address, bypassing any per-IP logic.
# The prefix list weighs ~55 against the SG's 60-rule ingress quota, so this SG
# has room for almost nothing else.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group_rule" "alb_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
  security_group_id = aws_security_group.alb_sg.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "allow_all_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_sg.id
}
# Additional resources for egress rules and NACLs should follow a similar pattern to above.


resource "aws_security_group" "postgres" {
  name        = "rds-postgres-sg"
  description = "Allow all inbound traffic"
  vpc_id      = aws_vpc.base_vpc.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.public_subnet_a.cidr_block, aws_subnet.public_subnet_b.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_subnet.public_subnet_a.cidr_block, aws_subnet.public_subnet_b.cidr_block]
  }

  tags = {
    Name = "Allow All"
  }
}

# Shared secret CloudFront sends to the ALB as X-Origin-Verify; each product's
# listener rule requires it (modules/product). Second layer behind the prefix
# list above: that one admits any CloudFront distribution, including someone
# else's pointed at our ALB. The CloudFront->ALB hop is http-only, so this
# crosses AWS's network in cleartext. Rotating it means applying every product
# stack: header first, then the rule, or the APIs 404 in between.
resource "random_password" "origin_verify" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "origin_verify" {
  name  = "/platform/alb/origin_verify"
  type  = "SecureString"
  value = random_password.origin_verify.result
}
