resource "aws_lb_target_group" "api" {
  name        = local.target_group_name
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.platform_vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    interval            = 30
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Matches X-Product-Id rather than host_header deliberately: header values
# survive a domain change, host rules would need editing every time a product
# moves to its own apex — a planned event.
resource "aws_lb_listener_rule" "api" {
  listener_arn = var.platform_alb_listener_arn
  priority     = var.alb_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  condition {
    http_header {
      http_header_name = "X-Product-Id"
      values           = [var.product]
    }
  }

  # X-Product-Id routes but is not a secret; this rejects anything that did not
  # come through one of our distributions. See platform/security.tf.
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [var.origin_verify_secret]
    }
  }
}
