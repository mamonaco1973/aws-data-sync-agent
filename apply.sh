#!/bin/bash
# ================================================================================
# Active Directory + Server + DataSync + Agent Deployment Orchestration Script
# ================================================================================
# Description:
#   Automates a four-phase AWS infrastructure build:
#     1. Active Directory (AD) Domain Controller.
#     2. Dependent EC2 servers and EFS that rely on the AD environment.
#     3. DataSync tasks and S3 destination bucket (agentless EFS-to-S3).
#     4. DataSync agent EC2 instance + SMB-to-S3 task (agent-based).
#
# Notes:
#   - Fail-fast enabled: any error terminates execution immediately.
#   - activate-agent.sh is run after Phase 4 to register the agent and
#     create the SMB source location and task via the AWS CLI.
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
DNS_ZONE="mcloud.mikecloud.com"

# ------------------------------------------------------------------------------
# Environment Pre-Check
# ------------------------------------------------------------------------------
echo "NOTE: Running environment validation..."
./check_env.sh

# ------------------------------------------------------------------------------
# Phase 1: Build AD Instance
# ------------------------------------------------------------------------------
echo "NOTE: Building Active Directory instance..."

cd 01-directory || { echo "ERROR: Directory 01-directory not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..

# ------------------------------------------------------------------------------
# Phase 2: Build EC2 Server Instances
# ------------------------------------------------------------------------------
echo "NOTE: Building EC2 server instances..."

cd 02-servers || { echo "ERROR: Directory 02-servers not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..

# ------------------------------------------------------------------------------
# Phase 3: Build DataSync Tasks and S3 Destination
# ------------------------------------------------------------------------------
echo "NOTE: Building DataSync infrastructure..."

cd 03-datasync || { echo "ERROR: Directory 03-datasync not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..

# ------------------------------------------------------------------------------
# Phase 4: Provision DataSync Agent EC2 Instance
# ------------------------------------------------------------------------------
echo "NOTE: Building DataSync agent instance..."

cd 04-agent || { echo "ERROR: Directory 04-agent not found"; exit 1; }

terraform init
terraform apply -auto-approve

cd ..

# ------------------------------------------------------------------------------
# Agent Activation: Register Agent and Create SMB Task
# ------------------------------------------------------------------------------
echo "NOTE: Activating DataSync agent and creating SMB task..."
./activate-agent.sh

# ------------------------------------------------------------------------------
# Build Validation
# ------------------------------------------------------------------------------
echo "NOTE: Running build validation..."
./validate.sh

echo "NOTE: Infrastructure build complete."
# ================================================================================
# End of Script
# ================================================================================
