#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   - Performs a controlled teardown of the full environment.
#   - Destroys resources in reverse dependency order.
#
# Scope:
#   - DataSync tasks, locations, and S3 bucket (03-datasync).
#   - EC2 server instances and EFS (02-servers).
#   - AWS Secrets Manager secrets for AD users and administrators.
#   - Active Directory infrastructure (01-directory).
#
# Notes:
#   - Secrets are deleted permanently with no recovery window.
#   - This action is destructive and cannot be undone.
#   - Intended for lab and demo environments only.
# ================================================================================

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"

# ------------------------------------------------------------------------------
# Phase 1: Destroy DataSync Infrastructure
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
# Phase 2: Destroy Server EC2 Instances
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
# Phase 3: Delete AD Secrets and Destroy AD Infrastructure
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
# Phase 4: Destroy Active Directory Infrastructure
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
