#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   - Performs a controlled teardown of the full environment.
#   - Destroys resources in reverse dependency order.
#
# Scope:
#   - Agent-based SMB task, locations, and DataSync agent (CLI-managed).
#   - DataSync agent EC2 instance (04-agent).
#   - DataSync EFS tasks, locations, and S3 bucket (03-datasync).
#   - EC2 server instances and EFS (02-servers).
#   - AWS Secrets Manager secrets for AD users and administrators.
#   - Active Directory infrastructure (01-directory).
#
# Notes:
#   - The SMB task and agent were created by activate-agent.sh outside
#     Terraform — they must be cleaned up via CLI before EC2 destroy.
#   - Secrets are deleted permanently with no recovery window.
#   - This action is destructive and cannot be undone.
#   - Intended for lab and demo environments only.
# ================================================================================

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"

# ------------------------------------------------------------------------------
# Phase 1: Delete SMB DataSync Task, Locations, and Agent
# ------------------------------------------------------------------------------
# Notes:
#   - The SMB task, SMB location, and agent were created by activate-agent.sh
#     outside of Terraform. They must be deleted via CLI before the S3 bucket
#     and agent EC2 can be destroyed.
#   - The agent cannot be deleted while tasks that reference it still exist.
# ------------------------------------------------------------------------------
echo "NOTE: Cleaning up agent-based DataSync resources..."

SMB_TASK_ARN=$(aws ssm get-parameter \
  --name "/datasync/smb-task-arn" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || true)

if [[ -n "${SMB_TASK_ARN}" ]]; then
  echo "NOTE: Deleting SMB DataSync task: ${SMB_TASK_ARN}"

  # Retrieve and delete source and destination locations before the task.
  SMB_SRC_ARN=$(aws datasync describe-task \
    --task-arn "${SMB_TASK_ARN}" \
    --query 'SourceLocationArn' \
    --output text 2>/dev/null || true)

  SMB_DST_ARN=$(aws datasync describe-task \
    --task-arn "${SMB_TASK_ARN}" \
    --query 'DestinationLocationArn' \
    --output text 2>/dev/null || true)

  # Retrieve agent ARN via the SMB location before deleting either resource.
  AGENT_ARN=$(aws datasync describe-location-smb \
    --location-arn "${SMB_SRC_ARN}" \
    --query 'AgentArns[0]' \
    --output text 2>/dev/null || true)

  aws datasync delete-task --task-arn "${SMB_TASK_ARN}" 2>/dev/null || true
  echo "NOTE: SMB task deleted."

  if [[ -n "${SMB_SRC_ARN}" ]] && [[ "${SMB_SRC_ARN}" != "None" ]]; then
    aws datasync delete-location --location-arn "${SMB_SRC_ARN}" 2>/dev/null || true
    echo "NOTE: SMB source location deleted."
  fi

  if [[ -n "${SMB_DST_ARN}" ]] && [[ "${SMB_DST_ARN}" != "None" ]]; then
    aws datasync delete-location --location-arn "${SMB_DST_ARN}" 2>/dev/null || true
    echo "NOTE: SMB S3 destination location deleted."
  fi

  if [[ -n "${AGENT_ARN}" ]] && [[ "${AGENT_ARN}" != "None" ]]; then
    aws datasync delete-agent --agent-arn "${AGENT_ARN}" 2>/dev/null || true
    echo "NOTE: DataSync agent deregistered."
  fi

  aws ssm delete-parameter --name "/datasync/smb-task-arn" 2>/dev/null || true
  echo "NOTE: SSM parameter /datasync/smb-task-arn deleted."
else
  echo "NOTE: No SMB task ARN found in SSM — skipping agent cleanup."
fi

echo ""

# ------------------------------------------------------------------------------
# Phase 2: Destroy DataSync Agent EC2 Instance
# ------------------------------------------------------------------------------
echo "NOTE: Destroying DataSync agent instance..."

cd 04-agent || { echo "ERROR: Directory 04-agent not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Phase 3: Destroy DataSync Infrastructure
# ------------------------------------------------------------------------------
# Notes:
#   - DataSync tasks and locations must be destroyed before EFS and S3 to
#     avoid dependency violations on the EFS file system and VPC ENIs.
# ------------------------------------------------------------------------------
echo "NOTE: Destroying DataSync infrastructure..."

cd 03-datasync || { echo "ERROR: Directory 03-datasync not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Phase 4: Destroy Server EC2 Instances
# ------------------------------------------------------------------------------
# Notes:
#   - Dependent servers must be destroyed before AD to avoid teardown
#     failures and dependency issues.
# ------------------------------------------------------------------------------
echo "NOTE: Destroying EC2 server instances..."

# Delete the EFS-ready sentinel so a fresh apply forces a new wait.
aws ssm delete-parameter --name "/datasync/efs-ready" 2>/dev/null || true

cd 02-servers || { echo "ERROR: Directory 02-servers not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Phase 5: Delete AD Secrets and Destroy AD Infrastructure
# ------------------------------------------------------------------------------
# Notes:
#   - Secrets are removed before AD teardown to avoid orphaned credentials.
#   - Deletion uses force-delete with no recovery window.
# ------------------------------------------------------------------------------
echo "NOTE: Deleting AD-related AWS secrets and parameters..."

# Permanently delete AD user and admin secrets from Secrets Manager.
aws secretsmanager delete-secret \
  --secret-id "akumar_ad_credentials_efs" \
  --force-delete-without-recovery

aws secretsmanager delete-secret \
  --secret-id "jsmith_ad_credentials_efs" \
  --force-delete-without-recovery

aws secretsmanager delete-secret \
  --secret-id "edavis_ad_credentials_efs" \
  --force-delete-without-recovery

aws secretsmanager delete-secret \
  --secret-id "rpatel_ad_credentials_efs" \
  --force-delete-without-recovery

aws secretsmanager delete-secret \
  --secret-id "admin_ad_credentials_efs" \
  --force-delete-without-recovery

# ------------------------------------------------------------------------------
# Phase 6: Destroy Active Directory Infrastructure
# ------------------------------------------------------------------------------
echo "NOTE: Destroying AD instance..."

cd 01-directory || { echo "ERROR: Directory 01-directory not found"; exit 1; }

terraform init
terraform destroy -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------
echo "NOTE: Infrastructure destruction complete."
# ================================================================================
# End of Script
# ================================================================================
