# ================================================================================
# FILE: variables.tf
#
# Purpose:
#   - Defines input variables for the DataSync phase.
#   - Controls VPC discovery and domain naming for data source lookups.
#
# Notes:
#   - Defaults match the values used in 01-directory and 02-servers.
# ================================================================================

# ------------------------------------------------------------------------------
# VARIABLE: vpc_name
# ------------------------------------------------------------------------------
# Purpose:
#   - Name tag used to locate the VPC created in 01-directory.
# ------------------------------------------------------------------------------
variable "vpc_name" {
  description = "Name tag of the VPC created in 01-directory"
  type        = string
  default     = "efs-vpc"
}
