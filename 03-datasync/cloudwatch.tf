# ================================================================================
# FILE: cloudwatch.tf
#
# Purpose:
#   - Creates a CloudWatch Log Group for DataSync task execution logs.
#   - Attaches a resource-based policy that allows the DataSync service
#     principal to write log events.
#
# Notes:
#   - DataSync uses a CloudWatch resource policy (not an IAM role) to authorize
#     log writes. The policy must be attached directly to the log group.
#   - Log retention is set to 30 days — adjust for longer-lived environments.
# ================================================================================

# ================================================================================
# RESOURCE: aws_cloudwatch_log_group.datasync
# ================================================================================
# Purpose:
#   - Destination for all DataSync task execution logs.
#   - Shared across all four tasks — each task execution writes to its own
#     log stream within this group.
# ================================================================================
resource "aws_cloudwatch_log_group" "datasync" {
  name              = "/datasync/efs-to-s3"
  retention_in_days = 30

  tags = { Name = "datasync-logs" }
}

# ================================================================================
# RESOURCE: aws_cloudwatch_log_resource_policy.datasync
# ================================================================================
# Purpose:
#   - Grants the DataSync service principal permission to create log streams
#     and put log events into the log group.
#
# Notes:
#   - This resource policy is required in addition to any IAM role permissions.
#     DataSync evaluates the resource policy on the log group independently.
#   - Resource is scoped to /datasync/* to restrict to DataSync log groups only.
# ================================================================================
resource "aws_cloudwatch_log_resource_policy" "datasync" {
  policy_name = "datasync-logs-policy-${random_id.suffix.hex}"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "datasync.amazonaws.com" }
      Action = [
        "logs:PutLogEvents",
        "logs:CreateLogStream"
      ]
      Resource = "${aws_cloudwatch_log_group.datasync.arn}:*"
    }]
  })
}

# ================================================================================
# OUTPUT: datasync_log_group
# ================================================================================
output "datasync_log_group" {
  description = "CloudWatch Log Group for DataSync task execution logs"
  value       = aws_cloudwatch_log_group.datasync.name
}
