###############################################################################
# Lambda — Slow Downstream Function (Chaos Scenario 3)
# Artificially introduces latency to simulate a struggling dependency
###############################################################################

data "archive_file" "slow_downstream" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/timeout-scenario"
  output_path = "${path.module}/../lambda/timeout-scenario.zip"
}

resource "aws_iam_role" "lambda_execution" {
  name = "${local.name_prefix}-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "slow_downstream" {
  function_name    = "${local.name_prefix}-slow-downstream"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.slow_downstream.output_path
  source_code_hash = data.archive_file.slow_downstream.output_base64sha256

  # Intentionally short timeout for chaos scenario — will trigger timeout errors
  timeout     = 3
  memory_size = 128

  environment {
    variables = {
      CHAOS_MODE          = "true"
      ARTIFICIAL_DELAY_MS = "4500"   # 4.5s delay > 3s timeout = guaranteed failure
      ENVIRONMENT         = var.environment
    }
  }

  # X-Ray tracing enabled so DevOps Agent can correlate traces
  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.lambda_logs]

  tags = var.tags
}

# Lambda URL for easy HTTP triggering during chaos tests
resource "aws_lambda_function_url" "slow_downstream" {
  function_name      = aws_lambda_function.slow_downstream.function_name
  authorization_type = "NONE"
}

output "lambda_function_url" {
  description = "HTTP URL to trigger the slow downstream Lambda"
  value       = aws_lambda_function_url.slow_downstream.function_url
}
