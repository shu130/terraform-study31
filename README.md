# Terraform勉強-第31回：SQSをトリガーにしてLambda関数を実行し、CloudWatchでログを確認する

githubリポジトリ：""

## SQSキューとLambda関数を連携させ、メッセージの処理やログの管理を行う仕組みをTerraformで構築する

```bash
.
├── provider.tf
├── sqs.tf
├── lambda.tf
├── sqs_message_batch_send.sh
├── src
│   ├── lambda_function.py
│   └── lambda_function.zip   
├── terraform.tfvars
└── variables.tf
```

## 1. `provider.tf`ファイル

今回は`provider.tf`のなかで**AWSアカウントID**を動的に取得する

```hcl:./provider.tf
# terraformとawsプロバイダのバージョン
terraform {
  required_version = ">= 1.6.2, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.4.0"
    }
  }
}

provider "aws" {
  profile = var.profile
  region  = var.region

  default_tags {
    tags = {
      "ManagedBy" = "Terraform"
      "Project"   = "tf-study31"
    }
  }
}

# アカウントIDを動的に取得
data "aws_caller_identity" "current" {}
```
- **`data "aws_caller_identity"`**: AWSアカウントIDやユーザーIDなどを動的に取得
- アカウントIDの場合は、`${data.aws_caller_identity.current.account_id}`と書くことでどこでも使える
---

## 2. `sqs.tf`ファイル

3つのSQSキュー（標準キュー、FIFOキュー、デッドレターキュー）を設定する。

### 1. 標準SQSキュー（`aws_sqs_queue "standard"`）

```hcl:sqs.tf
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
```
- **`delay_seconds`**: メッセージが送信されてから利用可能になるまでの遅延時間
- **`max_message_size`**: メッセージの最大サイズ（バイト単位）=>256KB
- **`message_retention_seconds`**: メッセージ保持時間（秒単位）=>4日間（345600秒）
- **`visibility_timeout_seconds`**: メッセージが他の受信者に見えなくなる期間 =>30秒に設定
- **`sqs_managed_sse_enabled`**: SQSの暗号化を有効
- **`policy`**: アクセス許可ポリシーでLambda関数がこのキューにアクセスできるよう、アカウントIDを含むARNを指定
- **`redrive_policy`**: メッセージが正常に処理されなかったときに`DLQ`に送るための設定
  - **deadLetterTargetArn**: DLQのキューARNを指定
  - **maxReceiveCount**: 最大2回までメッセージを再試行し、それでも失敗したらDLQに送信

### 2. FIFO SQSキュー（`aws_sqs_queue "fifo"`）

順序保証が必要なメッセージ処理に使われるFIFOキュー。  
**FIFOキューに固有の属性**: `fifo_queue`, `content_based_deduplication`, `fifo_throughput_limit`, `deduplication_scope` はFIFOキューに特有の設定。

```hcl:sqs.tf
#---------------------------
# SQS
#--------------------------
# FIFO SQSキュー
resource "aws_sqs_queue" "fifo" {
  name                              = "test-queue.fifo"
  fifo_queue                        = true
  content_based_deduplication       = true
  fifo_throughput_limit             = "perQueue"
  deduplication_scope               = "queue"
}
```

- **`fifo_queue`**: FIFOキューを有効にする
- **`content_based_deduplication`**: メッセージの重複排除を有効にする
- **`fifo_throughput_limit`**: FIFOキューのスループット制限 => キュー単位で制限
- **`deduplication_scope`**: 重複排除のスコープ => キュー全体


### 3. デッドレターキュー（`aws_sqs_queue "dlq"`）

失敗したメッセージが格納される専用キュー。  
標準のキューとFIFOキューで処理に失敗したメッセージがこのキューに送信される。

```hcl
resource "aws_sqs_queue" "dlq" {
  name = "test-DLQ-v2"
}
```
- 標準SQSキューの設定と同じ
- **name**: デッドレターキューの名前を`"test-DLQ-v2"`に設定


---

## 3. `lambda.tf`ファイル

IAMロール/ポリシー、Lambda関数を設定する。

### 1. IAMロール（`aws_iam_role "lambda_role"`）

```hcl:lambda.tf
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
```
- **IAMロール**: Lambdaに対してAWSリソース(SQS,CloudWatch)にアクセスする権限を持たせる
- **`assume_role_policy`**: Lambdaがこのロールを使用できるようにするためのポリシー


### 2. IAMポリシーのアタッチ（`aws_iam_role_policy_attachment`）

#### SQS用途：

```hcl:lambda.tf
# Lambda IAMポリシーのアタッチ
resource "aws_iam_role_policy_attachment" "lambda_sqs_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}
```
- **`aws_iam_role_policy_attachment`**: IAMロールに特定のIAMポリシーをアタッチ
- **`role`**: ここではLambda実行用IAMロールを指定
- **`policy_arn`**: アタッチするポリシーのARNを指定
  - **`AWSLambdaSQSQueueExecutionRole`**: Lambda関数がSQSキューをトリガーとして使用、SQSキューからメッセージを読み取り、Lambdaが処理を実行

#### CloudWatch用途：

```hcl:lambda.tf
# Lambda関数のCloudWatchログポリシーのアタッチ
resource "aws_iam_role_policy_attachment" "lambda_cloudwatch_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}
```
  - **`CloudWatchLogsFullAccess`**: CloudWatch Logsに対するフルアクセス権限をLambdaに与え、CloudWatch Logsにログを記録したり、ログの確認が可能にする  
  (権限が大きすぎるが、今回はこのマネージドポリシーを使用)

### 3. Lambdaで実行するPythonコード (`lambda_function.py`)

Lambda関数のエントリーポイントとなる関数名を`lambda_handler`として定義

```bash: ./src/lambda_function.py
import json

def lambda_handler(event, context):
    for record in event['Records']:
        print(f"Message Body: {record['body']}")

    return {
        'statusCode': 200,
        'body': json.dumps('Hello from Lambda!')
    }
```
- **`event`**:
  - Lambda関数をトリガーする際に送られてくるデータで、リクエストの内容が含まれる  
  例えば、S3のファイルアップロードやSQSのメッセージなどの情報 
- **`context`**:
  - Lambda関数の実行に関する情報が含まれており、メモリの使用量や実行時間など、関数実行時に使える情報が入る  
- **`for record in event['Records']:`**:
  - `event`の中にある`Records`というキーのリストにアクセスし、そのリスト内の各要素を順に`record`として処理する  
  - Lambdaは、複数のレコード（SQSメッセージやSNS通知など）を一度に受け取ることがあり、それらを`Records`というキーに格納する
 - **イベントを処理**:
   - `event['Records']`リストに含まれる各レコードのメッセージ本文（`record['body']`）を出力する
 - **結果の返却**:
   - 関数が正常に終了すると、`statusCode`として`200`、`body`として「Hello from Lambda!」というメッセージが含まれたレスポンスがJSON形式で返される

### 4. Lambda関数の設定 (`aws_lambda_function`)

Lambda関数を作成し、SQSキューからのメッセージをトリガーとして処理を実行し、CloudWatch Logsに結果を記録する。

```hcl:lambda.tf
#---------------------------
# Lambda
#---------------------------
# 関数の作成
resource "aws_lambda_function" "sqs_lambda" {
  filename         = "${path.module}/src/lambda_function.zip"
  function_name    = "sqs_lambda_handler"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"  #=># pythonコードの[ファイル名].[関数名]
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
```
 - **`resource "aws_lambda_function" "sqs_lambda"`**：
   - Lambda関数のリソース定義 
 - **`filename`**：
   - Lambda関数として実行するPythonコードのzipファイルパスを指定（`lambda_function.zip`）
   - `${path.module}`は、現在のTerraformモジュールのパス
 - **`function_name`**：
   - Lambda関数の名前 =>「sqs_lambda_handler」という名前で定義
 - **`role`**：
   - ここで前述のIAMロールのARNを指定
 - **`handler`**：  
   Lambda関数のエントリーポイントを指定:  
     - ここでは、`lambda_function.py`ファイルにある`lambda_handler`関数をエントリーポイントとして実行
     - `lambda_function.lambda_handler` の形式で指定することで、Pythonコード内の指定関数が実行される
 - **`runtime`**：
   - Lambda関数の実行環境を指定 => Python 3.11 を指定
 - **`source_code_hash`**：
   - Lambdaコードの変更を検出するためのハッシュ値で、コードが変更されるとハッシュが変わり、Lambda関数が再デプロイされる
 - **`environment`**：
   - Lambda関数の実行時に使用する環境変数を定義
   - `LOG_LEVEL`という環境変数を定義し、ログの出力レベルを制御
 - **`depends_on`**：
   - 依存関係を指定する属性: `aws_cloudwatch_log_group.lambda_log`が作成されるまでLambda関数の作成を待機し、実行時にCloudWatchログが確実に存在するようにする

---

### 5. SQSキューのトリガー設定 (`aws_lambda_event_source_mapping`)

Lambda関数がSQSのメッセージを受け取るトリガーとして動作するための設定。  
標準キューとFIFOキューの両方をトリガーとして設定する。

#### 標準キュー/FIFOキューのトリガー

```hcl:lambda.tf
# 標準キューのトリガー
resource "aws_lambda_event_source_mapping" "standard_sqs_trigger" {
  event_source_arn = aws_sqs_queue.standard.arn
  function_name    = aws_lambda_function.sqs_lambda.arn
  batch_size       = 10
  enabled          = true
}

# FIFOキューのトリガー
resource "aws_lambda_event_source_mapping" "fifo_sqs_trigger" {
  event_source_arn = aws_sqs_queue.fifo.arn
  function_name    = aws_lambda_function.sqs_lambda.arn
  batch_size       = 10
  enabled          = true
}
```
- **`event_source_arn`**：
   - Lambda関数のトリガーとなるSQSキューのARNを指定 => 標準キュー
- **`function_name`**：
   - トリガーを設定するLambda関数を指定: `aws_lambda_function.sqs_lambda.arn`でLambda関数のARNを指定
- **`batch_size`**：
   - 一度に読み込むメッセージ数 => 10件ずつSQSからメッセージを読み込んで処理する
- **`enabled`**：
   - トリガーを有効にする設定

---

### CloudWatch Logsの設定 (`aws_cloudwatch_log_group`)

Lambda関数が出力するログをCloudWatch Logsに記録するためのロググループの作成。

```hcl:lambda.tf
resource "aws_cloudwatch_log_group" "lambda_log" {
  name              = "/aws/lambda/sqs_lambda_handler"
  retention_in_days = 7
}
```
- **`name`**：
   - Lambda関数に関連するログは`/aws/lambda/{関数名}`の形式で保存される
   - 今回は `/aws/lambda/sqs_lambda_handler`という名前でロググループを作成される

- **`retention_in_days`**：
   - CloudWatch Logsで保存する期間を指定 => 7日間の保持期間を指定(7日後に古いログが自動で削除される)
---

## 4. `terraform apply`後の確認

- **`terraform state list`**：  
現在Terraformの状態に登録されているリソース一覧を表示  
リソースが想定通りに作成されているか確認

```bash
$ terraform state list
data.aws_caller_identity.current
aws_cloudwatch_log_group.lambda_log
aws_iam_role.lambda_role
aws_iam_role_policy_attachment.lambda_cloudwatch_policy
aws_iam_role_policy_attachment.lambda_sqs_policy
aws_lambda_event_source_mapping.fifo_sqs_trigger
aws_lambda_event_source_mapping.standard_sqs_trigger
aws_lambda_function.sqs_lambda
aws_sqs_queue.dlq
aws_sqs_queue.fifo
aws_sqs_queue.standard
```

- **`terraform show`**：  
`apply`で作成されたリソースの詳細情報を表示  
リソースの属性値（ARNなど）を確認するのに便利

```bash
$ terraform show | grep url
    url = "https://sqs.us-east-1.amazonaws.com/xxxxxxxxxxxx/test-DLQ-v2"
    url = "https://sqs.us-east-1.amazonaws.com/xxxxxxxxxxxx/test-queue-v2.fifo"
    url = "https://sqs.us-east-1.amazonaws.com/xxxxxxxxxxxx/test-queue-v2"

$ terraform show | grep log_group
# aws_cloudwatch_log_group.lambda_log:
resource "aws_cloudwatch_log_group" "lambda_log" {
    log_group_class = "STANDARD"
    log_group       = "/aws/lambda/sqs_lambda_handler"
```

## 5. 動作確認

#### **最新のログをフォロー（リアルタイムモニタリング）**

VScodeのターミナルで、  
`aws logs tail`コマンドで、Lambda関数が連続してトリガーされリアルタイムでログを待ち受けて確認する。

```bash
aws logs tail "/aws/lambda/sqs_lambda_handler" --follow
```
- `--follow`オプションで、新しいログが生成されるとリアルタイムで出力され続ける  
   SQSトリガーによるLambdaのログを逐次確認したいときに便利

#### SQSキューにメッセージを送信してLambdaがトリガーされるか確認

キューにメッセージを送信し、Lambda関数がトリガーされてCloudWatchログにメッセージが記録されるか確認

##### 標準キュー用コマンド：

```bash
aws sqs send-message-batch \
--queue-url "キューURL" \
--entries "$(seq 10 | jq -nR '[inputs | {Id: (.|tostring), MessageBody: ("standard:" + .)}]')"
```

##### FIFOキュー用コマンド：

```bash
aws sqs send-message-batch \
--queue-url "キューURL" \
--entries "$(seq 10 | jq -nR '[inputs | {Id: (.|tostring), MessageBody: ("fifo:" + .), MessageGroupId: "aaa"}]')"
```

### CloudWatchでLambda関数のログを確認するAWS CLIコマンド

#### 1. **ロググループのリスト表示**

Lambda関数に関連するCloudWatchロググループが存在するか確認する。

```bash
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/sqs_lambda_handler"
```

- => `/aws/lambda/`で始まるロググループの一覧が表示される (`sqs_lambda_handler`)

---

#### 2. **ログストリームのリスト表示**

Lambda関数の各実行ごとに異なるログストリームが作成される。  
最新のログストリームを確認する。

```bash
aws logs describe-log-streams --log-group-name "/aws/lambda/sqs_lambda_handler" --order-by "LastEventTime" --descending
```

- => 直近のログストリームIDを取得

---

#### 3. **最新のログイベントを取得**

取得したログストリームIDを使いLambda関数の最新の実行ログを表示する。

```bash
aws logs get-log-events --log-group-name "/aws/lambda/sqs_lambda_handler" --log-stream-name "<LogStreamName>" --limit 10
```

- `--limit 10`で表示するログの数を指定する

---

#### **エラーメッセージのみを検索**

エラーの確認には、以下のコマンドで「ERROR」などのキーワードを含むログイベントのみを検索できる。

```bash
aws logs filter-log-events --log-group-name "/aws/lambda/sqs_lambda_handler" --filter-pattern "ERROR"
```

- `--filter-pattern`で「ERROR」を含むログだけを出力できる  
   Lambda関数でエラーが発生している場合の確認に使用できる

---
今回はここまでにしたいと思います。