#!/usr/bin/env bash
set -euo pipefail

EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
mkdir -p "$EVIDENCE"

EXEC_ID=$(aws ssm start-automation-execution \
  --region ca-central-1 \
  --document-name ZTNA-HealthCheck \
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
  sleep 10
done

echo "Final status: $STATUS"

aws ssm get-automation-execution \
  --region ca-central-1 \
  --automation-execution-id "$EXEC_ID" \
  > "$EVIDENCE/health-check.json"

echo "Evidence: $EVIDENCE/health-check.json"
