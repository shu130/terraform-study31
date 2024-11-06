#!/bin/bash

# 標準キュー用コマンド：
aws sqs send-message-batch \
--queue-url [キューURL] \
--entries "$(seq 10 | jq -nR '[inputs | {Id: (.|tostring), MessageBody: ("standard:" + .)}]')"
# FIFOキュー用コマンド：
aws sqs send-message-batch \
--queue-url [キューURL] \
--entries "$(seq 10 | jq -nR '[inputs | {Id: (.|tostring), MessageBody: ("fifo:" + .), MessageGroupId: "aaa"}]')"