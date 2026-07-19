###############################################################################
# AWS DevOps Agent Lab — Terraform Module
# Provisions: Agent Space, IAM roles, CloudWatch integration, GitHub connection
# Author: Production Infrastructure Series
###############################################################################

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project_name}-${var.environment}"
}

###############################################################################
# IAM — DevOps Agent Execution Role
# Grants the agent permission to read your AWS resources for topology mapping
###############################################################################

resource "aws_iam_role" "devops_agent_execution" {
  name = "${local.name_prefix}-devops-agent-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # NOTE: Service principal name can vary by region.
          # Confirmed: "aidevops.amazonaws.com" (e.g. ap-southeast-2, us-east-1)
          # Verify in your region: https://docs.aws.amazon.com/devops-agent/latest/userguide
          Service = "aidevops.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })

  tags = var.tags
}

# Managed policy for DevOps Agent — read-only across services for topology
resource "aws_iam_role_policy" "devops_agent_readonly" {
  name = "${local.name_prefix}-devops-agent-readonly"
  role = aws_iam_role.devops_agent_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch — metrics, logs, alarms
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "logs:StartQuery",
          "logs:GetQueryResults"
        ]
        Resource = "*"
      },
      # EKS — cluster and workload inspection
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
          "eks:ListAddons",
          "eks:DescribeAddon"
        ]
        Resource = "*"
      },
      # EC2 — instances, VPCs, security groups for topology
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      },
      # Lambda — function config and invocation logs
      {
        Effect = "Allow"
        Action = [
          "lambda:ListFunctions",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListEventSourceMappings",
          "lambda:GetAccountSettings"
        ]
        Resource = "*"
      },
      # ECS — for hybrid workload environments
      {
        Effect = "Allow"
        Action = [
          "ecs:ListClusters",
          "ecs:DescribeClusters",
          "ecs:ListServices",
          "ecs:DescribeServices",
          "ecs:ListTasks",
          "ecs:DescribeTasks"
        ]
        Resource = "*"
      },
      # RDS — database health for cascade investigation
      {
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:DescribeDBClusters",
          "rds:DescribeEvents"
        ]
        Resource = "*"
      },
      # Resource tagging — for topology relationship mapping
      {
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "tag:GetTagKeys"
        ]
        Resource = "*"
      },
      # X-Ray — distributed tracing correlation
      {
        Effect = "Allow"
        Action = [
          "xray:GetTraceSummaries",
          "xray:GetServiceGraph",
          "xray:GetTraceGraph"
        ]
        Resource = "*"
      }
    ]
  })
}

###############################################################################
# IAM — Cross-Account Role (for multi-account environments)
# If your EKS cluster lives in a different account than the agent
###############################################################################

resource "aws_iam_role" "devops_agent_cross_account" {
  count = var.enable_cross_account ? 1 : 0
  name  = "${local.name_prefix}-devops-agent-cross-account-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-devops-agent-execution-role"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "devops_agent_cross_account_readonly" {
  count      = var.enable_cross_account ? 1 : 0
  role       = aws_iam_role.devops_agent_cross_account[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

###############################################################################
# CloudWatch — Alarms for the chaos scenarios
###############################################################################

# EKS Pod OOMKilled alarm — triggers DevOps Agent investigation
resource "aws_cloudwatch_metric_alarm" "eks_oom_alarm" {
  alarm_name          = "${local.name_prefix}-eks-oom-killed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "EKS node memory utilization exceeds 85% — potential OOMKill risk"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.devops_agent_alerts.arn]
  ok_actions    = [aws_sns_topic.devops_agent_alerts.arn]

  tags = var.tags
}

# Lambda timeout alarm
resource "aws_cloudwatch_metric_alarm" "lambda_timeout_alarm" {
  alarm_name          = "${local.name_prefix}-lambda-timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Lambda function error count exceeded threshold — possible timeouts"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = "${local.name_prefix}-slow-downstream"
  }

  alarm_actions = [aws_sns_topic.devops_agent_alerts.arn]

  tags = var.tags
}

# Deployment regression alarm — error rate spike
resource "aws_cloudwatch_metric_alarm" "app_error_rate_alarm" {
  alarm_name          = "${local.name_prefix}-app-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5xxError"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Application error rate spike — potential deployment regression"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.devops_agent_alerts.arn]

  tags = var.tags
}

###############################################################################
# SNS — Alert routing to DevOps Agent
###############################################################################

resource "aws_sns_topic" "devops_agent_alerts" {
  name = "${local.name_prefix}-devops-agent-alerts"
  tags = var.tags
}

resource "aws_sns_topic_policy" "devops_agent_alerts" {
  arn = aws_sns_topic.devops_agent_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.devops_agent_alerts.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:*"
          }
        }
      }
    ]
  })
}

###############################################################################
# CloudWatch Log Groups — structured logs for agent investigation
###############################################################################

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/devops-agent-lab/${var.environment}/app"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "eks_logs" {
  name              = "/aws/eks/${var.eks_cluster_name}/application"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.name_prefix}-slow-downstream"
  retention_in_days = 7
  tags              = var.tags
}

###############################################################################
# SSM Parameter Store — store integration credentials securely
###############################################################################

resource "aws_ssm_parameter" "github_token" {
  name        = "/${var.project_name}/${var.environment}/github-token"
  description = "GitHub PAT for DevOps Agent CI/CD correlation"
  type        = "SecureString"
  value       = var.github_token
  tags        = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}
