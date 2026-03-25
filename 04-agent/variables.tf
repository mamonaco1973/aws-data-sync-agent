# ================================================================================
# FILE: variables.tf
#
# Purpose:
#   - Declares input variables for the DataSync agent phase.
#
# Scope:
#   - VPC name used to locate the existing network baseline by tag.
# ================================================================================

# ================================================================================
# VARIABLE: vpc_name
# ================================================================================
# Purpose:
#   - Identifies the VPC provisioned in 01-directory for subnet discovery.
# ================================================================================
variable "vpc_name" {
  description = "Name tag of the VPC created in 01-directory"
  type        = string
  default     = "efs-vpc"
}
