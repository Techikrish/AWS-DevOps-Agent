###############################################################################
# Variables — AWS DevOps Agent Lab
###############################################################################

variable "aws_region" {
  description = "AWS region — DevOps Agent is available in us-east-1 (GA)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default     = "devops-agent-lab"
}

variable "environment" {
  description = "Environment label (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster to monitor"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ARN suffix of the Application Load Balancer for error rate alarms"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format for CI/CD correlation"
  type        = string
}

variable "github_token" {
  description = "GitHub PAT with repo and workflow read permissions"
  type        = string
  sensitive   = true
}

variable "enable_cross_account" {
  description = "Enable cross-account IAM role for multi-account setups"
  type        = bool
  default     = false
}

variable "slack_webhook_url" {
  description = "Slack webhook URL for incident notification routing"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "devops-agent-lab"
    ManagedBy   = "terraform"
    Series      = "production-infrastructure"
  }
}
