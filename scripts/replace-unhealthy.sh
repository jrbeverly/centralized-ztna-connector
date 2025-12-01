#!/usr/bin/env bash
set -euo pipefail

EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
mkdir -p "$EVIDENCE"

TARGET_REGION=us-east-1

UNHEALTHY_INSTANCE=$(aws ec2 describe-instances \
  --region "$TARGET_REGION" \
  --filters 'Name=tag:Component,Values=Connector' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

echo "Stopping ztna-mock on $UNHEALTHY_INSTANCE ($TARGET_REGION)"

CMD_ID=$(aws ssm send-command \
  --region "$TARGET_REGION" \
  --instance-ids "$UNHEALTHY_INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl stop ztna-mock"]' \
  --query 'Command.CommandId' \
  --output text)

while true; do
  CMD_STATUS=$(aws ssm get-command-invocation \
    --region "$TARGET_REGION" \
    --command-id "$CMD_ID" \
    --instance-id "$UNHEALTHY_INSTANCE" \
    --query Status \
    --output text)
  case "$CMD_STATUS" in
    Success|Failed|Cancelled|TimedOut) break;;
  esac
  sleep 5
done

echo "ztna-mock stopped (stop command: $CMD_STATUS)"

EXEC_ID=$(aws ssm start-automation-execution \
  --region ca-central-1 \
  --document-name ZTNA-ReplaceUnhealthy \
  --query AutomationExecutionId \
  --output text)

echo "Parent execution: $EXEC_ID"

while true; do
  STATUS=$(aws ssm get-automation-execution \
    --region ca-central-1 \
    --automation-execution-id "$EXEC_ID" \
    --query AutomationExecution.AutomationExecutionStatus \
    --output text)
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break;;
  esac
  sleep 15
done

echo "Final status: $STATUS"

aws ssm get-automation-execution \
  --region ca-central-1 \
  --automation-execution-id "$EXEC_ID" \
  > "$EVIDENCE/replace-unhealthy.json"

HEALTH_ID=$(aws ssm start-automation-execution \
  --region ca-central-1 \
  --document-name ZTNA-HealthCheck \
  --query AutomationExecutionId \
  --output text)

while true; do
  HEALTH_STATUS=$(aws ssm get-automation-execution \
    --region ca-central-1 \
    --automation-execution-id "$HEALTH_ID" \
    --query AutomationExecution.AutomationExecutionStatus \
    --output text)
  case "$HEALTH_STATUS" in
    Success|Failed|Cancelled|TimedOut) break;;
  esac
  sleep 10
done

aws ssm get-automation-execution \
  --region ca-central-1 \
  --automation-execution-id "$HEALTH_ID" \
  > "$EVIDENCE/post-replace-health-check.json"

echo "Evidence: $EVIDENCE/"
