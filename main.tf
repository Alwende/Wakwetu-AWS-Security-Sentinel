# 1. The Security Log Bucket (Hardened)
resource "aws_s3_bucket" "log_bucket" {
  bucket        = "wakwetu-security-logs-2026"
  force_destroy = true 
}

# 2. Prevent Public Access
resource "aws_s3_bucket_public_access_block" "log_bucket_block" {
  bucket = aws_s3_bucket.log_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 3. S3 Lifecycle Policy
resource "aws_s3_bucket_lifecycle_configuration" "log_lifecycle" {
  bucket = aws_s3_bucket.log_bucket.id

  rule {
    id     = "archive_old_logs"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# 4. S3 Bucket Policy (Expanded for CloudTrail AND Config)
resource "aws_s3_bucket_policy" "trail_policy" {
  bucket = aws_s3_bucket.log_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.log_bucket.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.log_bucket.arn}/AWSLogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.log_bucket.arn
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.log_bucket.arn}/AWSLogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

# 5. CloudTrail
resource "aws_cloudtrail" "main_trail" {
  name                          = "wakwetu-main-audit-trail"
  s3_bucket_name                = aws_s3_bucket.log_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  depends_on                    = [aws_s3_bucket_policy.trail_policy]
}

# 6. GuardDuty Detector
resource "aws_guardduty_detector" "main" {
  enable = true
}

# 7. SNS Topic
resource "aws_sns_topic" "security_alerts" {
  name = "wakwetu-security-alerts"
}

# 8. SNS Subscription
resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = "alwende8@gmail.com"
}

# 9. CloudWatch Event Rule
resource "aws_cloudwatch_event_rule" "guardduty_finding" {
  name        = "guardduty-finding-rule"
  description = "Trigger SNS for GuardDuty findings"
  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
  })
}

# 10. CloudWatch Event Target
resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_finding.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.security_alerts.arn
}

# 11. IAM Role for AWS Config
resource "aws_iam_role" "config_role" {
  name = "wakwetu-aws-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_policy" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# 12. Config Recorder
resource "aws_config_configuration_recorder" "main" {
  name     = "wakwetu-config-recorder"
  role_arn = aws_iam_role.config_role.arn
  recording_group {
    all_supported                = true
    include_global_resource_types = true
  }
}

# 13. Config Delivery Channel
resource "aws_config_delivery_channel" "main" {
  name           = "wakwetu-config-delivery"
  s3_bucket_name = aws_s3_bucket.log_bucket.id
  depends_on     = [aws_config_configuration_recorder.main]
}

# 14. Config Recorder Status
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# 15. Compliance Rule (Corrected Identifier)
resource "aws_config_config_rule" "s3_public_access" {
  name = "s3-bucket-public-access-prohibited"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}
