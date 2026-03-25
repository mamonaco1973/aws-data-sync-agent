# ================================================================================
# FILE: main.tf
#
# Purpose:
#   - Configures providers for the DataSync phase.
#   - Discovers existing infrastructure from 01-directory and 02-servers
#     via tag-based data sources.
#
# Scope:
#   - AWS and random provider declarations.
#   - VPC, subnet, and EFS file system data sources.
#
# Notes:
#   - This phase depends on 01-directory and 02-servers being fully applied.
#   - All data sources use Name tags for discovery — ensure tags are unique.
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
#   - Provides a unique suffix for S3 bucket and IAM resource names.
#   - Shared across s3.tf and iam.tf via this single resource.
# ================================================================================
resource "random_id" "suffix" {
  byte_length = 4
}

# ================================================================================
# DATA: VPC Discovery
# ================================================================================
# Purpose:
#   - Locates the VPC provisioned in 01-directory by Name tag.
# ================================================================================
data "aws_vpc" "ad_vpc" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# ================================================================================
# DATA: Subnet Discovery
# ================================================================================
# Purpose:
#   - Locates the public subnet where DataSync will create its ENI.
#
# Notes:
#   - DataSync creates an elastic network interface in this subnet to mount EFS.
#   - Must be in the same AZ as at least one EFS mount target.
# ================================================================================
data "aws_subnet" "vm_subnet_1" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.ad_vpc.id]
  }
  filter {
    name   = "tag:Name"
    values = ["vm-subnet-1"]
  }
}

# ================================================================================
# DATA: EFS File System Discovery
# ================================================================================
# Purpose:
#   - Locates the EFS file system provisioned in 02-servers by Name tag.
# ================================================================================
data "aws_efs_file_system" "efs" {
  tags = {
    Name = "mcloud-efs"
  }
}
