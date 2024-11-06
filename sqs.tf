# ./sqs.tf

#---------------------------
# SQS
#---------------------------
# 標準SQSキュー
resource "aws_sqs_queue" "standard" {
  name                              = "test-queue-v2"
  delay_seconds                     = 0
  max_message_size                  = 262144
  message_retention_seconds         = 345600
  visibility_timeout_seconds        = 30
  receive_wait_time_seconds         = 0
  sqs_managed_sse_enabled           = true
  kms_data_key_reuse_period_seconds = 300
  fifo_queue                        = false

  # ポリシー設定
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      },
      Action    = "SQS:*",
      Resource  = "arn:aws:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:test-queue-v2"
    }]
  })

  # デッドレターキュー設定
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn,
    maxReceiveCount     = 2
  })
}

# FIFO SQSキュー
resource "aws_sqs_queue" "fifo" {
  name                              = "test-queue-v2.fifo"
  delay_seconds                     = 0
  max_message_size                  = 262144
  message_retention_seconds         = 345600
  visibility_timeout_seconds        = 30
  receive_wait_time_seconds         = 0
  sqs_managed_sse_enabled           = true
  kms_data_key_reuse_period_seconds = 300
  fifo_queue                        = true
  content_based_deduplication       = true
  fifo_throughput_limit             = "perQueue"
  deduplication_scope               = "queue"

  # ポリシー設定
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "__owner_statement",
      Effect    = "Allow",
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      },
      Action    = "SQS:*",
      Resource  = "arn:aws:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:test-queue.fifo"
    }]
  })
}

# デッドレターキュー (DLQ)
resource "aws_sqs_queue" "dlq" {
  name                              = "test-DLQ-v2"
  delay_seconds                     = 0
  max_message_size                  = 262144
  message_retention_seconds         = 345600
  visibility_timeout_seconds        = 30
  receive_wait_time_seconds         = 0
  sqs_managed_sse_enabled           = true
  kms_data_key_reuse_period_seconds = 300
  fifo_queue                        = false

  # ポリシー設定
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      },
      Action    = "SQS:*",
      Resource  = "arn:aws:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:test-DLQ"
    }]
  })
}
