#!/bin/bash
# ================================================================================
# activate-agent.sh
#
# Purpose:
#   - Activates the DataSync agent EC2 instance provisioned in 04-agent.
#   - Creates an SMB source location pointing at the Samba share on the
#     efs-client-gateway instance.
#   - Creates an S3 destination location for the SMB transfer.
#   - Creates a DataSync task wiring SMB source to S3 destination.
#   - Stores the task ARN in SSM Parameter Store so validate.sh can include
#     the SMB task in its polling loop alongside the EFS tasks.
#
# Notes:
#   - Must be run after both 03-datasync and 04-agent Terraform phases complete.
#   - Requires curl, jq, and the AWS CLI in PATH.
#   - Agent activation is a one-time HTTP handshake — idempotent re-runs are
#     guarded by an SSM sentinel check at the top.
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVATION_TIMEOUT=300   # 5 minutes — agent boot and HTTP readiness
ACTIVATION_INTERVAL=10

# ------------------------------------------------------------------------------
# Idempotency Guard
# If the SMB task ARN already exists in SSM, activation was already completed.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Checking Activation State"
echo "============================================================================"
echo ""

EXISTING_ARN=$(aws ssm get-parameter \
  --name "/datasync/smb-task-arn" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || true)

if [[ -n "${EXISTING_ARN}" ]]; then
  echo "NOTE: SMB task already activated. ARN: ${EXISTING_ARN}"
  echo "NOTE: Skipping activation. Delete /datasync/smb-task-arn to re-activate."
  echo ""
  exit 0
fi

# ------------------------------------------------------------------------------
# Retrieve Agent Public IP from Terraform Output
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Retrieving Agent IP"
echo "============================================================================"
echo ""

AGENT_IP=$(terraform -chdir="${SCRIPT_DIR}/04-agent" output -raw agent_public_ip)

if [[ -z "${AGENT_IP}" ]]; then
  echo "ERROR: Could not retrieve agent_public_ip from 04-agent Terraform output."
  exit 1
fi

echo "NOTE: Agent IP: ${AGENT_IP}"
echo ""

# ------------------------------------------------------------------------------
# Poll Agent HTTP Endpoint for Activation Key
# The DataSync agent exposes an HTTP endpoint on port 80 during startup.
# A GET with the query string below returns the activation key as plain text.
# The no_redirect parameter prevents an HTTP 302 that would confuse curl -s.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Waiting for Activation Endpoint"
echo "============================================================================"
echo ""

ACTIVATION_URL="http://${AGENT_IP}/?gatewayType=SYNC&activationRegion=${AWS_DEFAULT_REGION}&endpointType=PUBLIC&no_redirect"
ELAPSED=0
ACTIVATION_KEY=""

while true; do
  RESPONSE=$(curl -s --max-time 5 "${ACTIVATION_URL}" 2>/dev/null || true)

  if [[ "${RESPONSE}" =~ ^[A-Z0-9-]+$ ]] && [[ ${#RESPONSE} -gt 10 ]]; then
    ACTIVATION_KEY="${RESPONSE}"
    echo "NOTE: Activation key received."
    break
  fi

  if [[ "${ELAPSED}" -ge "${ACTIVATION_TIMEOUT}" ]]; then
    echo "ERROR: Timed out waiting for DataSync agent activation endpoint."
    echo "       Check that port 80 is reachable at ${AGENT_IP}."
    exit 1
  fi

  echo "NOTE: Agent not ready yet — waiting... (${ELAPSED}s elapsed)"
  sleep "${ACTIVATION_INTERVAL}"
  ELAPSED=$(( ELAPSED + ACTIVATION_INTERVAL ))
done

echo ""

# ------------------------------------------------------------------------------
# Register Agent with DataSync Service
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Registering Agent"
echo "============================================================================"
echo ""

AGENT_ARN=$(aws datasync create-agent \
  --activation-key "${ACTIVATION_KEY}" \
  --agent-name "mcloud-datasync-agent" \
  --tags Key=Name,Value=mcloud-datasync-agent \
  --query 'AgentArn' \
  --output text)

echo "NOTE: Agent registered: ${AGENT_ARN}"
echo ""

# ------------------------------------------------------------------------------
# Discover efs-client-gateway Private IP
# The DataSync agent communicates with the Samba share over the private network.
# Using the private IP avoids routing through the internet gateway.
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
# Retrieve AD Admin Credentials from Secrets Manager
# The Samba share uses Active Directory authentication (security = ADS).
# DataSync needs valid AD credentials to authenticate against the SMB share.
# ------------------------------------------------------------------------------
ADMIN_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "admin_ad_credentials_efs" \
  --query 'SecretString' \
  --output text)

SMB_USER_RAW=$(echo "${ADMIN_SECRET}" | jq -r '.username')
SMB_PASSWORD=$(echo "${ADMIN_SECRET}" | jq -r '.password')

# Strip domain prefix (e.g. MCLOUD\Admin -> Admin). The --domain flag carries
# the domain; the --user field must be the bare username only.
SMB_USER="${SMB_USER_RAW##*\\}"

if [[ -z "${SMB_USER}" ]] || [[ -z "${SMB_PASSWORD}" ]]; then
  echo "ERROR: Could not parse username/password from admin_ad_credentials_efs."
  exit 1
fi

echo "NOTE: SMB credentials retrieved for user: ${SMB_USER}"
echo ""

# ------------------------------------------------------------------------------
# Create SMB Source Location
# The subdirectory /efs corresponds to the Samba share name on efs-client-gateway.
# Domain = MCLOUD (NetBIOS name of the Active Directory domain).
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Creating SMB Source Location"
echo "============================================================================"
echo ""

SMB_LOCATION_ARN=$(aws datasync create-location-smb \
  --server-hostname "${SMB_HOST}" \
  --subdirectory "/efs" \
  --user "${SMB_USER}" \
  --password "${SMB_PASSWORD}" \
  --domain "MCLOUD" \
  --agent-arns "${AGENT_ARN}" \
  --tags Key=Name,Value=smb-src-efs \
  --query 'LocationArn' \
  --output text)

echo "NOTE: SMB source location: ${SMB_LOCATION_ARN}"
echo ""

# ------------------------------------------------------------------------------
# Retrieve S3 Bucket and IAM Role ARNs from 03-datasync Terraform Outputs
# The SMB task writes to a dedicated /smb-efs prefix in the same S3 bucket
# used by the EFS tasks, reusing the same IAM role for S3 access.
# ------------------------------------------------------------------------------
S3_BUCKET=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_bucket_name)
DATASYNC_ROLE_ARN=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_role_arn)
LOG_GROUP=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_log_group)

if [[ -z "${S3_BUCKET}" ]] || [[ -z "${DATASYNC_ROLE_ARN}" ]]; then
  echo "ERROR: Could not retrieve S3 bucket or role ARN from 03-datasync output."
  exit 1
fi

S3_BUCKET_ARN="arn:aws:s3:::${S3_BUCKET}"

echo "NOTE: S3 bucket:  ${S3_BUCKET}"
echo "NOTE: Role ARN:   ${DATASYNC_ROLE_ARN}"
echo "NOTE: Log group:  ${LOG_GROUP}"
echo ""

# ------------------------------------------------------------------------------
# Create S3 Destination Location for SMB Transfer
# Uses the /smb-efs prefix to separate SMB-sourced files from EFS-sourced files.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Creating S3 Destination Location"
echo "============================================================================"
echo ""

S3_LOCATION_ARN=$(aws datasync create-location-s3 \
  --s3-bucket-arn "${S3_BUCKET_ARN}" \
  --subdirectory "/smb-efs" \
  --s3-config "BucketAccessRoleArn=${DATASYNC_ROLE_ARN}" \
  --tags Key=Name,Value=s3-dst-smb-efs \
  --query 'LocationArn' \
  --output text)

echo "NOTE: S3 destination location: ${S3_LOCATION_ARN}"
echo ""

# ------------------------------------------------------------------------------
# Create DataSync Task (SMB -> S3)
# Options mirror the EFS tasks: transfer changed files, remove deleted files,
# verify only transferred files, and log at TRANSFER level.
# CloudWatch log group is shared with the EFS tasks for consolidated visibility.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Creating SMB Task"
echo "============================================================================"
echo ""

LOG_GROUP_ARN=$(aws logs describe-log-groups \
  --log-group-name-prefix "${LOG_GROUP}" \
  --query 'logGroups[0].arn' \
  --output text)

TASK_ARN=$(aws datasync create-task \
  --name "sync-smb-efs" \
  --source-location-arn "${SMB_LOCATION_ARN}" \
  --destination-location-arn "${S3_LOCATION_ARN}" \
  --cloud-watch-log-group-arn "${LOG_GROUP_ARN}" \
  --options "TransferMode=CHANGED,PreserveDeletedFiles=REMOVE,VerifyMode=ONLY_FILES_TRANSFERRED,LogLevel=TRANSFER" \
  --tags Key=Name,Value=sync-smb-efs \
  --query 'TaskArn' \
  --output text)

echo "NOTE: SMB task created: ${TASK_ARN}"
echo ""

# ------------------------------------------------------------------------------
# Store Task ARN in SSM Parameter Store
# validate.sh reads this parameter and adds the SMB task to its polling loop
# alongside the EFS tasks, so all five tasks are monitored together.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync Agent — Storing Task ARN"
echo "============================================================================"
echo ""

aws ssm put-parameter \
  --name "/datasync/smb-task-arn" \
  --value "${TASK_ARN}" \
  --type "String" \
  --overwrite

echo "NOTE: Stored task ARN in SSM: /datasync/smb-task-arn"
echo ""
echo "NOTE: Agent activation complete."
echo ""
echo "      Agent ARN:           ${AGENT_ARN}"
echo "      SMB source location: ${SMB_LOCATION_ARN}"
echo "      S3 dest location:    ${S3_LOCATION_ARN}"
echo "      Task ARN:            ${TASK_ARN}"
echo ""
