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
# Phase 1: Delete SMB DataSync Tasks, Locations, and Agents
# ------------------------------------------------------------------------------
# Notes:
#   - Four tasks (two per agent) and their locations were created by
#     activate-agent.sh outside Terraform. They must be deleted via CLI.
#   - Collect all agent ARNs first; delete agents only after all tasks and
#     locations referencing them have been removed.
#   - The agent cannot be deleted while tasks or locations reference it.
# ------------------------------------------------------------------------------
echo "NOTE: Cleaning up agent-based DataSync resources..."

declare -a TASK_ARNS=()
declare -a SMB_ARNS=()
declare -a S3_ARNS=()
declare -A AGENT_ARNS=()  # associative to deduplicate the two agents

for PROJECT in aws-efs aws-mgn-example aws-workspaces aws-mysql; do
  TASK_ARN=$(aws ssm get-parameter \
    --name "/datasync/smb-task-arn/${PROJECT}" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)

  [[ -z "${TASK_ARN}" ]] && continue

  echo "NOTE: Found task for ${PROJECT}: ${TASK_ARN}"
  TASK_ARNS+=("${TASK_ARN}")

  SMB_SRC=$(aws datasync describe-task \
    --task-arn "${TASK_ARN}" \
    --query 'SourceLocationArn' --output text 2>/dev/null || true)
  S3_DST=$(aws datasync describe-task \
    --task-arn "${TASK_ARN}" \
    --query 'DestinationLocationArn' --output text 2>/dev/null || true)

  [[ -n "${SMB_SRC}" && "${SMB_SRC}" != "None" ]] && SMB_ARNS+=("${SMB_SRC}")
  [[ -n "${S3_DST}"  && "${S3_DST}"  != "None" ]] && S3_ARNS+=("${S3_DST}")

  AGENT_ARN=$(aws datasync describe-location-smb \
    --location-arn "${SMB_SRC}" \
    --query 'AgentArns[0]' --output text 2>/dev/null || true)
  [[ -n "${AGENT_ARN}" && "${AGENT_ARN}" != "None" ]] && AGENT_ARNS["${AGENT_ARN}"]=1
done

# Cancel any in-progress executions before deleting tasks.
for TASK_ARN in "${TASK_ARNS[@]}"; do
  ACTIVE_EXEC=$(aws datasync list-task-executions \
    --task-arn "${TASK_ARN}" \
    --query 'TaskExecutions[?Status!=`SUCCESS` && Status!=`ERROR`].TaskExecutionArn' \
    --output text 2>/dev/null || true)

  if [[ -n "${ACTIVE_EXEC}" ]]; then
    echo "NOTE: Cancelling active execution: ${ACTIVE_EXEC}"
    aws datasync cancel-task-execution --task-execution-arn "${ACTIVE_EXEC}"
    CANCEL_WAIT=0
    until [[ "${CANCEL_WAIT}" -ge 120 ]]; do
      STATUS=$(aws datasync describe-task-execution \
        --task-execution-arn "${ACTIVE_EXEC}" \
        --query 'Status' --output text 2>/dev/null || echo "UNKNOWN")
      [[ "${STATUS}" == "ERROR" || "${STATUS}" == "SUCCESS" ]] && break
      echo "NOTE: Waiting for execution to stop (${STATUS})..."
      sleep 10
      CANCEL_WAIT=$(( CANCEL_WAIT + 10 ))
    done
  fi
done

# Delete all tasks first, then locations, then agents.
for TASK_ARN in "${TASK_ARNS[@]}"; do
  aws datasync delete-task --task-arn "${TASK_ARN}"
  echo "NOTE: Task deleted: ${TASK_ARN}"
done

for SMB_ARN in "${SMB_ARNS[@]}"; do
  aws datasync delete-location --location-arn "${SMB_ARN}"
  echo "NOTE: SMB location deleted: ${SMB_ARN}"
done

for S3_ARN in "${S3_ARNS[@]}"; do
  aws datasync delete-location --location-arn "${S3_ARN}"
  echo "NOTE: S3 location deleted: ${S3_ARN}"
done

for AGENT_ARN in "${!AGENT_ARNS[@]}"; do
  aws datasync delete-agent --agent-arn "${AGENT_ARN}"
  echo "NOTE: Agent deregistered: ${AGENT_ARN}"
done

# Delete SSM parameters for all four projects.
for PROJECT in aws-efs aws-mgn-example aws-workspaces aws-mysql; do
  aws ssm delete-parameter --name "/datasync/smb-task-arn/${PROJECT}" 2>/dev/null || true
done
echo "NOTE: SSM parameters deleted."

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
