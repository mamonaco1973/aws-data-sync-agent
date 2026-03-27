#!/bin/bash
# ================================================================================
# activate-agent.sh
#
# Purpose:
#   - Activates two DataSync agent EC2 instances provisioned in 04-agent.
#   - Distributes four project directories across both agents (two each).
#   - Creates SMB source locations, S3 destination locations, and DataSync
#     tasks for each project, then stores task ARNs in SSM Parameter Store.
#
# Agent assignment:
#   - Agent 1: aws-efs, aws-mgn-example
#   - Agent 2: aws-workspaces, aws-mysql
#
# Notes:
#   - Must be run after both 03-datasync and 04-agent Terraform phases complete.
#   - Requires curl, jq, and the AWS CLI in PATH.
#   - Idempotent — guarded by SSM sentinel checks at the top.
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVATION_TIMEOUT=300
ACTIVATION_INTERVAL=10

# Projects assigned to each agent: "name:subdirectory" pairs.
AGENT_1_PROJECTS=("aws-efs:/aws-efs" "aws-mgn-example:/aws-mgn-example")
AGENT_2_PROJECTS=("aws-workspaces:/aws-workspaces" "aws-mysql:/aws-mysql")

# ------------------------------------------------------------------------------
# Idempotency Guard
# All four task ARNs must exist in SSM for activation to be considered complete.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Checking Activation State"
echo "============================================================================"
echo ""

ALL_PRESENT=true
for PROJECT in aws-efs aws-mgn-example aws-workspaces aws-mysql; do
  EXISTING=$(aws ssm get-parameter \
    --name "/datasync/smb-task-arn/${PROJECT}" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)
  if [[ -z "${EXISTING}" ]]; then
    ALL_PRESENT=false
    break
  fi
done

if [[ "${ALL_PRESENT}" == "true" ]]; then
  echo "NOTE: All SMB tasks already activated. Skipping."
  echo "NOTE: Delete /datasync/smb-task-arn/* parameters to re-activate."
  echo ""
  exit 0
fi

# ------------------------------------------------------------------------------
# Retrieve Agent IPs from Terraform Output
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Retrieving Agent IPs"
echo "============================================================================"
echo ""

AGENT_1_IP=$(terraform -chdir="${SCRIPT_DIR}/04-agent" output -raw agent_1_public_ip)
AGENT_2_IP=$(terraform -chdir="${SCRIPT_DIR}/04-agent" output -raw agent_2_public_ip)

echo "NOTE: Agent 1 IP: ${AGENT_1_IP}"
echo "NOTE: Agent 2 IP: ${AGENT_2_IP}"
echo ""

# ------------------------------------------------------------------------------
# Helper: activate_agent <ip> <name>
# Polls the agent HTTP endpoint, retrieves the activation key, and registers
# the agent with the DataSync service. Returns the agent ARN via echo.
# ------------------------------------------------------------------------------
activate_agent() {
  local IP="${1}"
  local NAME="${2}"
  local ACTIVATION_URL="http://${IP}/?gatewayType=SYNC&activationRegion=${AWS_DEFAULT_REGION}&endpointType=PUBLIC&no_redirect"
  local ELAPSED=0
  local KEY=""

  echo "NOTE: Waiting for ${NAME} activation endpoint (${IP})..."
  while true; do
    local RESPONSE
    RESPONSE=$(curl -s --max-time 5 "${ACTIVATION_URL}" 2>/dev/null || true)
    if [[ "${RESPONSE}" =~ ^[A-Z0-9-]+$ ]] && [[ ${#RESPONSE} -gt 10 ]]; then
      KEY="${RESPONSE}"
      echo "NOTE: ${NAME} activation key received."
      break
    fi
    if [[ "${ELAPSED}" -ge "${ACTIVATION_TIMEOUT}" ]]; then
      echo "ERROR: Timed out waiting for ${NAME} activation endpoint (${IP})."
      exit 1
    fi
    echo "NOTE: ${NAME} not ready yet — waiting... (${ELAPSED}s elapsed)"
    sleep "${ACTIVATION_INTERVAL}"
    ELAPSED=$(( ELAPSED + ACTIVATION_INTERVAL ))
  done

  local ARN
  ARN=$(aws datasync create-agent \
    --activation-key "${KEY}" \
    --agent-name "${NAME}" \
    --tags Key=Name,Value="${NAME}" \
    --query 'AgentArn' --output text)

  echo "NOTE: ${NAME} registered: ${ARN}"
  echo "${ARN}"
}

# ------------------------------------------------------------------------------
# Activate Both Agents
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Activating Agents"
echo "============================================================================"
echo ""

AGENT_1_ARN=$(activate_agent "${AGENT_1_IP}" "mcloud-datasync-agent-1" | tail -1)
echo ""
AGENT_2_ARN=$(activate_agent "${AGENT_2_IP}" "mcloud-datasync-agent-2" | tail -1)
echo ""

# ------------------------------------------------------------------------------
# Discover efs-client-gateway Private IP
# Both agents connect to the same Samba server. Using the private IP keeps
# traffic within the VPC and avoids routing through the internet gateway.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Discovering SMB Server"
echo "============================================================================"
echo ""

SMB_HOST=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=efs-client-gateway" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

if [[ -z "${SMB_HOST}" ]] || [[ "${SMB_HOST}" == "None" ]]; then
  echo "ERROR: Could not find running efs-client-gateway instance."
  exit 1
fi

echo "NOTE: SMB server private IP: ${SMB_HOST}"
echo ""

# ------------------------------------------------------------------------------
# Retrieve AD Credentials from Secrets Manager
# rpatel is used because it has a uidNumber set in AD, making it a valid
# POSIX identity on the Linux side. Admin has no uidNumber and cannot be
# mapped by winbind, causing authentication to fail at the share level.
# ------------------------------------------------------------------------------
ADMIN_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "rpatel_ad_credentials_efs" \
  --query 'SecretString' --output text)

SMB_USER_RAW=$(echo "${ADMIN_SECRET}" | jq -r '.username')
SMB_PASSWORD=$(echo "${ADMIN_SECRET}" | jq -r '.password')
SMB_USER="${SMB_USER_RAW##*\\}"

if [[ -z "${SMB_USER}" ]] || [[ -z "${SMB_PASSWORD}" ]]; then
  echo "ERROR: Could not parse credentials from rpatel_ad_credentials_efs."
  exit 1
fi

echo "NOTE: SMB credentials retrieved for user: ${SMB_USER}"
echo ""

# ------------------------------------------------------------------------------
# Retrieve S3 and CloudWatch Resources from 03-datasync Terraform Outputs
# Both agents write to the same S3 bucket and log to the same log group,
# reusing the IAM role and CloudWatch infrastructure from Phase 3.
# ------------------------------------------------------------------------------
S3_BUCKET=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_bucket_name)
DATASYNC_ROLE_ARN=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_role_arn)
LOG_GROUP=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_log_group)

S3_BUCKET_ARN="arn:aws:s3:::${S3_BUCKET}"

LOG_GROUP_ARN=$(aws logs describe-log-groups \
  --log-group-name-prefix "${LOG_GROUP}" \
  --query 'logGroups[0].arn' --output text)

echo "NOTE: S3 bucket:      ${S3_BUCKET}"
echo "NOTE: Role ARN:       ${DATASYNC_ROLE_ARN}"
echo "NOTE: Log group:      ${LOG_GROUP}"
echo ""

# ------------------------------------------------------------------------------
# Helper: create_task <agent_arn> <agent_label> <project_name> <subdirectory>
# Creates an SMB source location, S3 destination location, and DataSync task
# for a single project directory. Stores the task ARN in SSM.
# ------------------------------------------------------------------------------
create_task() {
  local AGENT_ARN="${1}"
  local AGENT_LABEL="${2}"
  local PROJECT="${3}"
  local SUBDIR="${4}"

  echo "--------------------------------------------------------------------"
  echo "NOTE: Creating task for ${PROJECT} (${AGENT_LABEL})"
  echo "--------------------------------------------------------------------"

  # SMB source location — subdirectory is relative to the share root (/efs).
  local SMB_ARN
  SMB_ARN=$(aws datasync create-location-smb \
    --server-hostname "${SMB_HOST}" \
    --subdirectory "${SUBDIR}" \
    --user "${SMB_USER}" \
    --password "${SMB_PASSWORD}" \
    --domain "MCLOUD" \
    --agent-arns "${AGENT_ARN}" \
    --tags Key=Name,Value="smb-src-${PROJECT}" \
    --query 'LocationArn' --output text)

  echo "NOTE: SMB source:  ${SMB_ARN}"

  # S3 destination location — one prefix per project.
  local S3_ARN
  S3_ARN=$(aws datasync create-location-s3 \
    --s3-bucket-arn "${S3_BUCKET_ARN}" \
    --subdirectory "/${PROJECT}" \
    --s3-config "BucketAccessRoleArn=${DATASYNC_ROLE_ARN}" \
    --tags Key=Name,Value="s3-dst-${PROJECT}" \
    --query 'LocationArn' --output text)

  echo "NOTE: S3 dest:     ${S3_ARN}"

  # DataSync task wiring source to destination.
  local TASK_ARN
  TASK_ARN=$(aws datasync create-task \
    --name "sync-${PROJECT}" \
    --source-location-arn "${SMB_ARN}" \
    --destination-location-arn "${S3_ARN}" \
    --cloud-watch-log-group-arn "${LOG_GROUP_ARN}" \
    --options "TransferMode=CHANGED,PreserveDeletedFiles=REMOVE,VerifyMode=ONLY_FILES_TRANSFERRED,LogLevel=TRANSFER" \
    --tags Key=Name,Value="sync-${PROJECT}" \
    --query 'TaskArn' --output text)

  echo "NOTE: Task ARN:    ${TASK_ARN}"

  # Store task ARN in SSM so validate.sh can read it without Terraform state.
  aws ssm put-parameter \
    --name "/datasync/smb-task-arn/${PROJECT}" \
    --value "${TASK_ARN}" \
    --type "String" \
    --overwrite

  echo "NOTE: Stored in SSM: /datasync/smb-task-arn/${PROJECT}"
  echo ""
}

# ------------------------------------------------------------------------------
# Create Tasks for Agent 1 (aws-efs, aws-mgn-example)
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent 1 — Creating Tasks"
echo "============================================================================"
echo ""

for ENTRY in "${AGENT_1_PROJECTS[@]}"; do
  PROJECT="${ENTRY%%:*}"
  SUBDIR="${ENTRY##*:}"
  create_task "${AGENT_1_ARN}" "agent-1" "${PROJECT}" "${SUBDIR}"
done

# ------------------------------------------------------------------------------
# Create Tasks for Agent 2 (aws-workspaces, aws-mysql)
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent 2 — Creating Tasks"
echo "============================================================================"
echo ""

for ENTRY in "${AGENT_2_PROJECTS[@]}"; do
  PROJECT="${ENTRY%%:*}"
  SUBDIR="${ENTRY##*:}"
  create_task "${AGENT_2_ARN}" "agent-2" "${PROJECT}" "${SUBDIR}"
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Activation Complete"
echo "============================================================================"
echo ""
echo "NOTE: Agent 1 ARN: ${AGENT_1_ARN}"
echo "      Tasks:       aws-efs, aws-mgn-example"
echo ""
echo "NOTE: Agent 2 ARN: ${AGENT_2_ARN}"
echo "      Tasks:       aws-workspaces, aws-mysql"
echo ""
