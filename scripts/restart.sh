#!/usr/bin/env bash
set -euo pipefail

EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
mkdir -p "$EVIDENCE"

EXEC_ID=$(aws ssm start-automation-execution \
  --region ca-central-1 \
  --document-name ZTNA-ControlledRestart \
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
  > "$EVIDENCE/controlled-restart.json"

for REGION in ca-central-1 us-east-1; do
  CHILD=$(aws ssm describe-automation-executions \
    --region "$REGION" \
    --filters "Key=ParentExecutionId,Values=$EXEC_ID" \
    --query 'AutomationExecutionMetadataList[0].AutomationExecutionId' \
    --output text)

  [ -z "$CHILD" ] && continue

  echo "Child execution ($REGION): $CHILD"

  aws ssm get-automation-execution \
    --region "$REGION" \
    --automation-execution-id "$CHILD" \
    > "$EVIDENCE/controlled-restart-$REGION.json"

  COMMANDS=$(aws ssm describe-automation-step-executions \
    --region "$REGION" \
    --automation-execution-id "$CHILD" \
    --query 'StepExecutions[*].Outputs.CommandId[]' \
    --output text)

  INSTANCES=$(aws ssm describe-automation-step-executions \
    --region "$REGION" \
    --automation-execution-id "$CHILD" \
    --query 'StepExecutions[*].Outputs.InstanceIds[]' \
    --output text | sort -u)

  for CMD in $COMMANDS; do
    for INST in $INSTANCES; do
      aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$CMD" \
        --instance-id "$INST" \
        > "$EVIDENCE/controlled-restart-$REGION-$CMD.json"
    done
  done
done

echo "Evidence: $EVIDENCE/controlled-restart*.json"
