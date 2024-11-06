# ./lambda.tf

#---------------------------
# IAM
#---------------------------
# Lambda実行用IAMロール
resource "aws_iam_role" "lambda_role" {
  name = "lambda_sqs_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Lambda IAMポリシーのアタッチ
resource "aws_iam_role_policy_attachment" "lambda_sqs_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# Lambda関数のCloudWatchログポリシーのアタッチ
resource "aws_iam_role_policy_attachment" "lambda_cloudwatch_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

#---------------------------
# Lambda
#---------------------------
# 関数の作成
resource "aws_lambda_function" "sqs_lambda" {
  filename         = "${path.module}/src/lambda_function.zip"
  function_name    = "sqs_lambda_handler"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = filebase64sha256("${path.module}/src/lambda_function.zip")

  environment {
    variables = {
      LOG_LEVEL = "INFO"
    }
  }

  # CloudWatchロググループ
  depends_on = [aws_cloudwatch_log_group.lambda_log]
}

# SQS標準キューのトリガー設定
resource "aws_lambda_event_source_mapping" "standard_sqs_trigger" {
  event_source_arn = aws_sqs_queue.standard.arn
  function_name    = aws_lambda_function.sqs_lambda.arn
  batch_size       = 10
  enabled          = true
}

# SQS FIFOキューのトリガー設定
resource "aws_lambda_event_source_mapping" "fifo_sqs_trigger" {
  event_source_arn = aws_sqs_queue.fifo.arn
  function_name    = aws_lambda_function.sqs_lambda.arn
  batch_size       = 10
  enabled          = true
}

#---------------------------
# CloudWatch
#---------------------------
# CloudWatchのロググループ
resource "aws_cloudwatch_log_group" "lambda_log" {
  name              = "/aws/lambda/sqs_lambda_handler"
  retention_in_days = 7
}