# ================================================================================
# FILE: s3.tf
#
# Purpose:
#   - Provisions the S3 bucket that receives data from EFS via DataSync.
#
# Scope:
#   - S3 bucket with unique name, encryption, versioning, and public access block.
#
# Notes:
#   - force_destroy = true allows Terraform to empty and delete the bucket on
#     destroy without manual intervention — appropriate for lab environments.
#   - Bucket name uses a random suffix for global uniqueness.
# ================================================================================

# ================================================================================
# RESOURCE: aws_s3_bucket.datasync
# ================================================================================
resource "aws_s3_bucket" "datasync" {
  bucket        = "mcloud-datasync-${random_id.suffix.hex}"
  force_destroy = true

  tags = {
    Name = "mcloud-datasync"
  }
}

# ================================================================================
# RESOURCE: aws_s3_bucket_versioning.datasync
# ================================================================================
# Purpose:
#   - Retains previous object versions — useful for recovery after a bad sync.
# ================================================================================
resource "aws_s3_bucket_versioning" "datasync" {
  bucket = aws_s3_bucket.datasync.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ================================================================================
# RESOURCE: aws_s3_bucket_server_side_encryption_configuration.datasync
# ================================================================================
# Purpose:
#   - Encrypts all objects at rest using AES-256 (SSE-S3).
# ================================================================================
resource "aws_s3_bucket_server_side_encryption_configuration" "datasync" {
  bucket = aws_s3_bucket.datasync.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ================================================================================
# RESOURCE: aws_s3_bucket_public_access_block.datasync
# ================================================================================
# Purpose:
#   - Blocks all public access to the DataSync destination bucket.
# ================================================================================
resource "aws_s3_bucket_public_access_block" "datasync" {
  bucket                  = aws_s3_bucket.datasync.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ================================================================================
# OUTPUT: datasync_bucket_name
# ================================================================================
output "datasync_bucket_name" {
  description = "Name of the S3 bucket receiving DataSync transfers"
  value       = aws_s3_bucket.datasync.bucket
}
