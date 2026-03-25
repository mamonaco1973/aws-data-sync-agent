# ================================================================================
# FILE: main.tf
#
# Purpose:
#   - Configures providers for the S3 destination and supporting infrastructure.
#
# Scope:
#   - AWS and random provider declarations.
#   - Shared random suffix for globally unique resource names.
#
# Notes:
#   - This phase provisions the S3 bucket, IAM role, and CloudWatch log group
#     that the agent-based SMB task (created by activate-agent.sh) will use.
#   - No EFS or VPC data sources are needed — the DataSync agent handles
#     connectivity to the SMB source independently.
# ================================================================================

# ================================================================================
# Terraform Provider Requirements
# ================================================================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ================================================================================
# AWS Provider Configuration
# ================================================================================
provider "aws" {
  region = "us-east-1"
}

# ================================================================================
# RANDOM: Shared Suffix
# ================================================================================
# Purpose:
#   - Provides a unique suffix for S3 bucket, IAM role, and CloudWatch policy
#     names to avoid collisions across stacks.
# ================================================================================
resource "random_id" "suffix" {
  byte_length = 4
}
