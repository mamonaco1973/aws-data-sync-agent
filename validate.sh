#!/bin/bash
# ================================================================================
# validate.sh
#
# Purpose:
#   - Reads DataSync task ARNs from Terraform output in 03-datasync.
#   - Starts all four DataSync tasks concurrently.
#   - Polls each task execution until all reach SUCCESS or any reach ERROR.
#
# Notes:
#   - Requires jq for parsing Terraform JSON output.
#   - All four tasks run in parallel — each transfers one EFS project to S3.
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=15
MAX_WAIT=3600  # 1 hour — DataSync transfers can take time depending on data size

# ------------------------------------------------------------------------------
# Wait for EFS Population to Complete
# userdata.sh writes /datasync/efs-ready to SSM Parameter Store when all git
# repos are cloned into EFS. Poll until it appears before starting tasks.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync — Waiting for EFS Population"
echo "============================================================================"
echo ""

EFS_WAIT_MAX=1800  # 30 minutes — git clones + package installs can be slow
EFS_ELAPSED=0
until aws ssm get-parameter --name "/datasync/efs-ready" --query 'Parameter.Value' --output text 2>/dev/null | grep -q "ready"; do
  if [[ "${EFS_ELAPSED}" -ge "${EFS_WAIT_MAX}" ]]; then
    echo "ERROR: Timed out waiting for EFS population sentinel (/datasync/efs-ready)."
    exit 1
  fi
  echo "NOTE: EFS not ready yet — waiting... (${EFS_ELAPSED}s elapsed)"
  sleep 30
  EFS_ELAPSED=$(( EFS_ELAPSED + 30 ))
done

echo "NOTE: EFS population complete. Starting DataSync tasks."
echo ""

# ------------------------------------------------------------------------------
# Read DataSync Task ARNs from Terraform Output
# Terraform outputs a JSON map of { project-name: task-arn }.
# Parse into an associative array for named tracking through execution.
# Also check SSM for the agent-based SMB task ARN created by activate-agent.sh.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync — Starting Tasks"
echo "============================================================================"
echo ""

declare -A TASK_MAP
while IFS=$'\t' read -r NAME ARN; do
  TASK_MAP["${NAME}"]="${ARN}"
done < <(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -json datasync_task_arns \
  | jq -r 'to_entries[] | [.key, .value] | @tsv')

# Add the SMB agent task if activate-agent.sh has been run.
SMB_TASK_ARN=$(aws ssm get-parameter \
  --name "/datasync/smb-task-arn" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || true)

if [[ -n "${SMB_TASK_ARN}" ]]; then
  TASK_MAP["smb-efs"]="${SMB_TASK_ARN}"
  echo "NOTE: SMB agent task found — adding to run."
else
  echo "NOTE: No SMB agent task found in SSM — running EFS tasks only."
fi
echo ""

if [[ "${#TASK_MAP[@]}" -eq 0 ]]; then
  echo "ERROR: No DataSync tasks found in 03-datasync Terraform output."
  exit 1
fi

# ------------------------------------------------------------------------------
# Start All Tasks Concurrently
# Each start-task-execution call returns a unique execution ARN used for polling.
# ------------------------------------------------------------------------------
declare -A EXEC_MAP
for NAME in "${!TASK_MAP[@]}"; do
  TASK_ARN="${TASK_MAP[${NAME}]}"
  EXEC_ARN=$(aws datasync start-task-execution \
    --task-arn "${TASK_ARN}" \
    --query 'TaskExecutionArn' \
    --output text)
  EXEC_MAP["${NAME}"]="${EXEC_ARN}"
  echo "NOTE: Started ${NAME}"
  echo "      Task:      ${TASK_ARN}"
  echo "      Execution: ${EXEC_ARN}"
  echo ""
done

# ------------------------------------------------------------------------------
# Poll Until All Executions Complete
# Statuses: QUEUED → LAUNCHING → PREPARING → TRANSFERRING → VERIFYING → SUCCESS
# Terminal error state: ERROR
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync — Waiting for All Tasks to Complete"
echo "============================================================================"
echo ""

ELAPSED=0
while true; do
  ALL_DONE=true

  for NAME in "${!EXEC_MAP[@]}"; do
    EXEC_ARN="${EXEC_MAP[${NAME}]}"
    STATUS=$(aws datasync describe-task-execution \
      --task-execution-arn "${EXEC_ARN}" \
      --query 'Status' \
      --output text 2>/dev/null || echo "UNKNOWN")

    echo "NOTE: ${NAME} — ${STATUS}"

    case "${STATUS}" in
      SUCCESS)
        ;;
      ERROR)
        echo "ERROR: DataSync task ${NAME} failed."
        echo "       Execution ARN: ${EXEC_ARN}"
        exit 1
        ;;
      *)
        ALL_DONE=false
        ;;
    esac
  done

  if [[ "${ALL_DONE}" == "true" ]]; then
    echo ""
    echo "NOTE: All DataSync tasks completed successfully."
    break
  fi

  if [[ "${ELAPSED}" -ge "${MAX_WAIT}" ]]; then
    echo "ERROR: Timed out after ${MAX_WAIT}s waiting for DataSync tasks."
    exit 1
  fi

  sleep "${POLL_INTERVAL}"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
  echo ""
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "============================================================================"
echo "DataSync — Transfer Summary"
echo "============================================================================"
echo ""

BUCKET=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_bucket_name 2>/dev/null || true)

for NAME in "${!EXEC_MAP[@]}"; do
  EXEC_ARN="${EXEC_MAP[${NAME}]}"
  RESULT=$(aws datasync describe-task-execution \
    --task-execution-arn "${EXEC_ARN}" \
    --query '[Status, Result.TransferredCount, Result.VerifiedCount]' \
    --output text 2>/dev/null || echo "UNKNOWN")
  echo "NOTE: ${NAME} — ${RESULT}"
done

if [[ -n "${BUCKET}" ]]; then
  echo ""
  echo "NOTE: Destination bucket: s3://${BUCKET}"
  echo ""
  aws s3 ls s3://${BUCKET}/
  echo ""
fi

# ------------------------------------------------------------------------------
# Download CloudWatch Logs
# DataSync log stream names use the format task-{ID}-exec-{ID}, derived from
# the execution ARN. e.g. arn:...:task/task-ABC/execution/exec-XYZ becomes
# task-ABC-exec-XYZ. Each stream is written to datasync-<name>.log in the
# project root.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync — Downloading CloudWatch Logs"
echo "============================================================================"
echo ""

LOG_GROUP=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_log_group 2>/dev/null || true)
RUN_TS=$(date -u +"%Y%m%d-%H%M%S")

if [[ -n "${LOG_GROUP}" ]]; then
  for NAME in "${!EXEC_MAP[@]}"; do
    EXEC_ARN="${EXEC_MAP[${NAME}]}"
    LOG_STREAM=$(echo "${EXEC_ARN}" | sed 's|arn:aws:datasync:[^:]*:[^:]*:task/\(task-[^/]*\)/execution/\(exec-[^/]*\)|\1-\2|')
    LOG_FILE="${SCRIPT_DIR}/datasync-${NAME}-${RUN_TS}.log"

    aws logs get-log-events \
      --log-group-name "${LOG_GROUP}" \
      --log-stream-name "${LOG_STREAM}" \
      --output json 2>/dev/null \
      | jq -r '.events[].message' > "${LOG_FILE}" || true

    if [[ -s "${LOG_FILE}" ]]; then
      echo "NOTE: ${NAME} — $(wc -l < "${LOG_FILE}") log lines -> $(basename "${LOG_FILE}")"
    else
      echo "WARN: ${NAME} — no log events found (stream may not exist yet)"
      rm -f "${LOG_FILE}"
    fi
  done
else
  echo "WARN: Could not retrieve log group name from Terraform output."
fi

echo ""
echo "NOTE: Validation complete."
echo ""
