terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# LocalStack provider — all requests go to http://localhost:4566
provider "aws" {
  access_key = "test"
  secret_key = "test"
  region     = "us-east-1"

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3          = "http://localhost:4566"
    lambda      = "http://localhost:4566"
    iam         = "http://localhost:4566"
    cloudwatch  = "http://localhost:4566"
    cloudwatchlogs = "http://localhost:4566"
  }
}

# ──────────────────────────────────────────────
# S3 Buckets
# ──────────────────────────────────────────────

resource "aws_s3_bucket" "start" {
  bucket        = "s3-start"
  force_destroy = true
}

resource "aws_s3_bucket" "finish" {
  bucket        = "s3-finish"
  force_destroy = true
}

# ──────────────────────────────────────────────
# Lifecycle policy on s3-start
# ──────────────────────────────────────────────

resource "aws_s3_bucket_lifecycle_configuration" "start_lifecycle" {
  bucket = aws_s3_bucket.start.id

  rule {
    id     = "expire-after-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# ──────────────────────────────────────────────
# IAM role for Lambda
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "lambda-s3-copy-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.start.arn}/*"]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.finish.arn}/*"]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "cloudwatch:PutMetricData"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_s3_policy" {
  name   = "lambda-s3-access"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.s3_access.json
}

# ──────────────────────────────────────────────
# Lambda function
# ──────────────────────────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/copy_file.py"
  output_path = "${path.module}/lambda/copy_file.zip"
}

resource "aws_lambda_function" "copy_file" {
  function_name    = "copy-file-lambda"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "copy_file.handler"
  runtime          = "python3.12"

  environment {
    variables = {
      DEST_BUCKET      = aws_s3_bucket.finish.id
      AWS_ENDPOINT_URL = "http://host.docker.internal:4566"
    }
  }
}

resource "aws_cloudwatch_log_group" "copy_file_log_group" {
  name              = "/aws/lambda/copy-file-lambda"
  retention_in_days = 14
}

resource "aws_cloudwatch_metric_alarm" "lambda_error_alarm" {
  alarm_name          = "copy-file-lambda-error-alarm"
  alarm_description   = "Alarm when Lambda reports errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  dimensions = {
    FunctionName = aws_lambda_function.copy_file.function_name
  }
}

# Allow S3 to invoke the Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.copy_file.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.start.arn
}

# ──────────────────────────────────────────────
# S3 event notification → Lambda on object upload
# ──────────────────────────────────────────────

resource "aws_s3_bucket_notification" "start_trigger" {
  bucket = aws_s3_bucket.start.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.copy_file.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
