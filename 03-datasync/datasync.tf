# ================================================================================
# FILE: datasync.tf
#
# Purpose:
#   - Transfers the four git project directories from EFS to S3 using
#     AWS DataSync, with one independent task per project for concurrency.
#
# Scope:
#   - DataSync security group for the ENI DataSync creates in the VPC.
#   - Four EFS source locations (one per project subdirectory).
#   - Four S3 destination locations (one per S3 prefix).
#   - Four DataSync tasks that can execute concurrently.
#
# Notes:
#   - DataSync does not require a separate agent EC2 instance for EFS sources.
#     It creates an elastic network interface directly in the specified subnet.
#   - Each task requires its own source location — the subdirectory is baked
#     into the location resource, not the task.
#   - Tasks are defined here but not auto-executed. Trigger with:
#       aws datasync start-task-execution --task-arn <arn>
# ================================================================================

# ================================================================================
# LOCAL: Project Map
# ================================================================================
# Purpose:
#   - Maps each project name to its EFS subdirectory path.
#   - Used as the for_each key across all three resource types so that
#     EFS location, S3 location, and task are consistently named and linked.
# ================================================================================
locals {
  projects = {
    aws-efs         = "/aws-efs"
    aws-mgn-example = "/aws-mgn-example"
    aws-workspaces  = "/aws-workspaces"
    aws-mysql       = "/aws-mysql"
  }
}

# ================================================================================
# RESOURCE: aws_security_group.datasync_sg
# ================================================================================
# Purpose:
#   - Attached to the ENI that DataSync creates in vm-subnet-1 to mount EFS.
#   - Requires outbound access to reach EFS mount targets (TCP/2049) and
#     AWS service endpoints (HTTPS/443).
#
# Notes:
#   - The EFS security group (efs-sg) already allows inbound TCP/2049 from
#     0.0.0.0/0, so no inbound rule is needed here for lab use.
# ================================================================================
resource "aws_security_group" "datasync_sg" {
  name        = "datasync-sg"
  description = "Security group for DataSync ENI - outbound to EFS and AWS APIs"
  vpc_id      = data.aws_vpc.ad_vpc.id

  # ------------------------------------------------------------------------------
  # EGRESS: ALL
  # Allows DataSync to reach EFS mount targets and AWS service endpoints.
  # ------------------------------------------------------------------------------
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "datasync-sg" }
}

# ================================================================================
# RESOURCES: aws_datasync_location_efs (one per project)
# ================================================================================
# Purpose:
#   - Defines the EFS subdirectory DataSync will read from for each project.
#
# Notes:
#   - ec2_config instructs DataSync which subnet and security group to use
#     when creating its ENI to mount the EFS file system.
# ================================================================================
resource "aws_datasync_location_efs" "projects" {
  for_each = local.projects

  efs_file_system_arn = data.aws_efs_file_system.efs.arn
  subdirectory        = each.value

  ec2_config {
    security_group_arns = [aws_security_group.datasync_sg.arn]
    subnet_arn          = data.aws_subnet.vm_subnet_1.arn
  }

  tags = { Name = "efs-src-${each.key}" }
}

# ================================================================================
# RESOURCES: aws_datasync_location_s3 (one per project)
# ================================================================================
# Purpose:
#   - Defines the S3 prefix DataSync will write to for each project.
#
# Notes:
#   - s3_config.bucket_access_role_arn is the IAM role DataSync assumes
#     to authenticate against S3 — must have the permissions in iam.tf.
# ================================================================================
resource "aws_datasync_location_s3" "projects" {
  for_each = local.projects

  s3_bucket_arn = aws_s3_bucket.datasync.arn
  subdirectory  = "/${each.key}"

  s3_config {
    bucket_access_role_arn = aws_iam_role.datasync_role.arn
  }

  tags = { Name = "s3-dst-${each.key}" }
}

# ================================================================================
# RESOURCES: aws_datasync_task (one per project)
# ================================================================================
# Purpose:
#   - Wires each EFS source location to its corresponding S3 destination.
#   - Tasks are independent and can be started concurrently.
#
# Notes:
#   - transfer_mode = CHANGED skips files already in sync, making reruns fast.
#   - preserve_deleted_files = REMOVE keeps S3 in sync with EFS deletions.
#   - verify_mode = ONLY_FILES_TRANSFERRED avoids a full post-transfer scan
#     while still confirming transferred files landed correctly.
# ================================================================================
resource "aws_datasync_task" "projects" {
  for_each = local.projects

  name                     = "sync-${each.key}"
  source_location_arn      = aws_datasync_location_efs.projects[each.key].arn
  destination_location_arn = aws_datasync_location_s3.projects[each.key].arn

  # ------------------------------------------------------------------------------
  # CloudWatch Logging
  # TRANSFER level logs every file transferred, skipped, and verified.
  # The ARN must end with :* — DataSync requires the log stream wildcard suffix.
  # ------------------------------------------------------------------------------
  cloudwatch_log_group_arn = "${aws_cloudwatch_log_group.datasync.arn}:*"

  options {
    bytes_per_second       = -1
    transfer_mode          = "CHANGED"
    preserve_deleted_files = "REMOVE"
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    log_level              = "TRANSFER"
  }

  # Resource policy must exist before DataSync can write logs.
  depends_on = [aws_cloudwatch_log_resource_policy.datasync]

  tags = { Name = "sync-${each.key}" }
}

# ================================================================================
# OUTPUT: datasync_task_arns
# ================================================================================
# Purpose:
#   - Exposes task ARNs so they can be passed to start-task-execution.
# ================================================================================
output "datasync_task_arns" {
  description = "ARNs of the four DataSync tasks — pass to start-task-execution"
  value       = { for k, v in aws_datasync_task.projects : k => v.arn }
}
