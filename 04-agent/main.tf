# ================================================================================
# FILE: main.tf
#
# Purpose:
#   - Configures the AWS provider for the DataSync agent phase.
#   - Discovers existing infrastructure from 01-directory via tag-based
#     data sources.
#
# Scope:
#   - AWS provider declaration.
#   - VPC and subnet data sources.
#
# Notes:
#   - This phase depends on 01-directory and 02-servers being fully applied.
#   - The DataSync agent EC2 is placed in vm-subnet-1 (public subnet) so that
#     the activation call can reach its HTTP endpoint from outside the VPC.
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
  }
}

# ================================================================================
# AWS Provider Configuration
# ================================================================================
provider "aws" {
  region = "us-east-1"
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
#   - Locates the public subnet where the DataSync agent EC2 will be placed.
#
# Notes:
#   - vm-subnet-1 is the public subnet with an internet-routable IP.
#   - The agent requires outbound internet access to reach DataSync endpoints.
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
