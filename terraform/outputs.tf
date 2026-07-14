###############################################################################
# Outputs — AWS DevOps Agent Lab
###############################################################################

output "devops_agent_execution_role_arn" {
  description = "ARN of the DevOps Agent execution role — paste this into Agent Space setup"
  value       = aws_iam_role.devops_agent_execution.arn
}

output "cross_account_role_arn" {
  description = "ARN of cross-account role (if enabled)"
  value       = var.enable_cross_account ? aws_iam_role.devops_agent_cross_account[0].arn : "not enabled"
}

output "sns_topic_arn" {
  description = "SNS topic ARN — configure this as the alarm action in CloudWatch"
  value       = aws_sns_topic.devops_agent_alerts.arn
}

output "cloudwatch_alarms" {
  description = "List of CloudWatch alarm names created for chaos scenarios"
  value = {
    oom_alarm        = aws_cloudwatch_metric_alarm.eks_oom_alarm.alarm_name
    lambda_timeout   = aws_cloudwatch_metric_alarm.lambda_timeout_alarm.alarm_name
    app_error_rate   = aws_cloudwatch_metric_alarm.app_error_rate_alarm.alarm_name
  }
}

output "log_group_names" {
  description = "CloudWatch log group names for the lab environment"
  value = {
    app    = aws_cloudwatch_log_group.app_logs.name
    eks    = aws_cloudwatch_log_group.eks_logs.name
    lambda = aws_cloudwatch_log_group.lambda_logs.name
  }
}

output "github_token_ssm_path" {
  description = "SSM Parameter path where GitHub token is stored"
  value       = aws_ssm_parameter.github_token.name
}

output "next_steps" {
  description = "Setup instructions after terraform apply"
  value       = <<-EOT
    ============================================================
    NEXT STEPS — AWS DevOps Agent Lab Setup
    ============================================================
    1. Go to AWS Console → DevOps Agent → Create Agent Space
    2. Paste the execution role ARN: ${aws_iam_role.devops_agent_execution.arn}
    3. Connect CloudWatch using SNS topic: ${aws_sns_topic.devops_agent_alerts.arn}
    4. Connect GitHub using token from SSM: ${aws_ssm_parameter.github_token.name}
    5. Enable topology scan on cluster: ${var.eks_cluster_name}
    6. Run chaos scenarios from /eks/chaos/ directory
    7. Watch the agent investigate in the Agent Space web app
    ============================================================
  EOT
}
