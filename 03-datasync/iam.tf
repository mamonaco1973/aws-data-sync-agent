# ================================================================================
# FILE: iam.tf
#
# Purpose:
#   - Creates an IAM role that DataSync assumes to write to S3.
#
# Scope:
#   - IAM role trusted by datasync.amazonaws.com.
#   - Inline policy granting the minimum S3 permissions required for transfer.
#
# Notes:
#   - Role name includes a random suffix to avoid collisions across stacks.
#   - DataSync requires GetBucketLocation and ListBucket on the bucket itself,
#     and object-level permissions on the bucket/* prefix.
# ================================================================================

# ================================================================================
# RESOURCE: aws_iam_role.datasync_role
# ================================================================================
resource "aws_iam_role" "datasync_role" {
  name = "datasync-s3-role-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "datasync.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ================================================================================
# RESOURCE: aws_iam_role_policy.datasync_s3_policy
# ================================================================================
# Purpose:
#   - Grants DataSync full read/write access to the destination bucket.
#
# Notes:
#   - AbortMultipartUpload and ListMultipartUploadParts are required for large
#     file transfers that DataSync splits into multipart uploads.
# ================================================================================
resource "aws_iam_role_policy" "datasync_s3_policy" {
  name = "datasync-s3-access"
  role = aws_iam_role.datasync_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListMultipartUploadParts",
        "s3:PutObject",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ]
      Resource = [
        aws_s3_bucket.datasync.arn,
        "${aws_s3_bucket.datasync.arn}/*"
      ]
    }]
  })
}
