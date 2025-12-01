#!/usr/bin/env bash
set -euo pipefail

CENTRAL=ca-central-1
TARGET=us-east-1
REGIONS="$CENTRAL $TARGET"

EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/evidence"
mkdir -p "$EVIDENCE"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

child_execution() {
  local parent=$1 region=$2
  aws ssm describe-automation-executions \
    --region "$region" \
    --filters "Key=ParentExecutionId,Values=$parent" \
    --query 'AutomationExecutionMetadataList[0].AutomationExecutionId' \
    --output text
}

wait_execution() {
  local id=$1
  local status
  while true; do
    status=$(aws ssm get-automation-execution \
      --region "$CENTRAL" \
      --automation-execution-id "$id" \
      --query AutomationExecution.AutomationExecutionStatus \
      --output text)
    case "$status" in Success|Failed|Cancelled|TimedOut) break;; esac
    sleep 10
  done
  echo "$status"
}

wait_invocation() {
  local region=$1 cmd=$2 inst=$3
  local status
  while true; do
    status=$(aws ssm get-command-invocation \
      --region "$region" \
      --command-id "$cmd" \
      --instance-id "$inst" \
      --query Status \
      --output text)
    case "$status" in Success|Failed|Cancelled|TimedOut) break;; esac
    sleep 5
  done
  echo "$status"
}

instance_tag() {
  local region=$1 instance=$2 key=$3
  aws ec2 describe-instances \
    --region "$region" --instance-ids "$instance" \
    --query "Reservations[0].Instances[0].Tags[?Key==\`$key\`] | [0].Value" \
    --output text
}

echo "=== 1. Tag-selected placement and inventory ==="

for region in $REGIONS; do
  aws cloudformation describe-stacks \
    --region "$region" \
    --stack-name "ztna-connector-$region" \
    > "$EVIDENCE/00-stack-$region.json" \
    || fail "connector stack ztna-connector-$region is missing"

  STACK_STATUS=$(aws cloudformation describe-stacks \
    --region "$region" \
    --stack-name "ztna-connector-$region" \
    --query 'Stacks[0].StackStatus' \
    --output text)
  case "$STACK_STATUS" in
    CREATE_COMPLETE|UPDATE_COMPLETE) ;;
    *) fail "connector stack ztna-connector-$region has status $STACK_STATUS" ;;
  esac

  aws cloudformation describe-stacks \
    --region "$region" \
    --stack-name "ztna-operations-$region" \
    > "$EVIDENCE/00-operations-stack-$region.json" \
    || fail "operations stack ztna-operations-$region is missing"

  COUNT=$(aws ec2 describe-instances \
    --region "$region" \
    --filters 'Name=tag:Component,Values=Connector' 'Name=instance-state-name,Values=running' \
    --query 'length(Reservations[].Instances[])' \
    --output text)
  [ "$COUNT" = 1 ] || fail "expected exactly 1 running connector in $region, found $COUNT"

  INSTANCE=$(aws ec2 describe-instances \
    --region "$region" \
    --filters 'Name=tag:Component,Values=Connector' 'Name=instance-state-name,Values=running' \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

  aws ec2 describe-instances \
    --region "$region" --instance-ids "$INSTANCE" \
    > "$EVIDENCE/01-placement-$region.json"

  VPC=$(aws ec2 describe-instances \
    --region "$region" --instance-ids "$INSTANCE" \
    --query 'Reservations[0].Instances[0].VpcId' --output text)
  SUBNET=$(aws ec2 describe-instances \
    --region "$region" --instance-ids "$INSTANCE" \
    --query 'Reservations[0].Instances[0].SubnetId' --output text)

  VPC_ELIGIBLE=$(aws ec2 describe-vpcs \
    --region "$region" --vpc-ids "$VPC" \
    --query 'Vpcs[0].Tags[?Key==`ZTNAConnector`] | [0].Value' --output text)
  [ "$VPC_ELIGIBLE" = Enabled ] || fail "VPC $VPC ($region) lacks ZTNAConnector=Enabled"

  SUBNET_ELIGIBLE=$(aws ec2 describe-subnets \
    --region "$region" --subnet-ids "$SUBNET" \
    --query 'Subnets[0].Tags[?Key==`ZTNAConnector`] | [0].Value' --output text)
  [ "$SUBNET_ELIGIBLE" = Enabled ] || fail "subnet $SUBNET ($region) lacks ZTNAConnector=Enabled"

  SUBNET_ENV=$(aws ec2 describe-subnets \
    --region "$region" --subnet-ids "$SUBNET" \
    --query 'Subnets[0].Tags[?Key==`Environment`] | [0].Value' --output text)
  [ "$SUBNET_ENV" = Production ] || fail "subnet $SUBNET ($region) lacks Environment=Production"

  [ "$(instance_tag "$region" "$INSTANCE" ManagedBy)" = ZTNA ] || fail "$INSTANCE ($region) lacks ManagedBy=ZTNA"
  [ "$(instance_tag "$region" "$INSTANCE" Component)" = Connector ] || fail "$INSTANCE ($region) lacks Component=Connector"
  [ "$(instance_tag "$region" "$INSTANCE" ConnectorGroup)" = "production-$region" ] || fail "$INSTANCE ($region) has the wrong ConnectorGroup"
  [ "$(instance_tag "$region" "$INSTANCE" VPC)" = "$VPC" ] || fail "$INSTANCE ($region) VPC tag does not match its VPC"

  echo "$region: connector $INSTANCE in tag-eligible VPC $VPC / subnet $SUBNET"
done

CENTRAL_INSTANCE=$(aws ec2 describe-instances \
  --region "$CENTRAL" \
  --filters 'Name=tag:Component,Values=Connector' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)
TARGET_INSTANCE=$(aws ec2 describe-instances \
  --region "$TARGET" \
  --filters 'Name=tag:Component,Values=Connector' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

echo "=== 2. Healthy fleet health (central, parameter-free) ==="

HEALTH_ID=$(aws ssm start-automation-execution \
  --region "$CENTRAL" \
  --document-name ZTNA-HealthCheck \
  --query AutomationExecutionId \
  --output text) || fail "ZTNA-HealthCheck did not start"
echo "execution: $HEALTH_ID"
HEALTH_STATUS=$(wait_execution "$HEALTH_ID")
aws ssm get-automation-execution \
  --region "$CENTRAL" --automation-execution-id "$HEALTH_ID" \
  > "$EVIDENCE/02-initial-health.json"
[ "$HEALTH_STATUS" = Success ] || fail "initial fleet health: expected Success, got $HEALTH_STATUS"
for region in $REGIONS; do
  CHILD=$(child_execution "$HEALTH_ID" "$region")
  [ -n "$CHILD" ] && [ "$CHILD" != None ] || fail "no child execution for $HEALTH_ID in $region"
  aws ssm get-automation-execution \
    --region "$region" --automation-execution-id "$CHILD" \
    > "$EVIDENCE/02-initial-health-$region.json"
done
echo "initial fleet health: $HEALTH_STATUS"

echo "=== 3. Fault injection: stop ztna-mock on the target connector ==="

STOP_CMD=$(aws ssm send-command \
  --region "$TARGET" \
  --instance-ids "$TARGET_INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl stop ztna-mock"]' \
  --query 'Command.CommandId' \
  --output text) || fail "stop command did not start"

STOP_STATUS=$(wait_invocation "$TARGET" "$STOP_CMD" "$TARGET_INSTANCE")
aws ssm get-command-invocation \
  --region "$TARGET" --command-id "$STOP_CMD" --instance-id "$TARGET_INSTANCE" \
  > "$EVIDENCE/03-stop-mock.json"
[ "$STOP_STATUS" = Success ] || fail "stopping ztna-mock: expected Success, got $STOP_STATUS"
echo "ztna-mock stopped on $TARGET_INSTANCE ($TARGET)"

echo "=== 4. Unhealthy fleet health (central, parameter-free) ==="

UNHEALTHY_ID=$(aws ssm start-automation-execution \
  --region "$CENTRAL" \
  --document-name ZTNA-HealthCheck \
  --query AutomationExecutionId \
  --output text) || fail "ZTNA-HealthCheck did not start"
echo "execution: $UNHEALTHY_ID"
UNHEALTHY_STATUS=$(wait_execution "$UNHEALTHY_ID")
aws ssm get-automation-execution \
  --region "$CENTRAL" --automation-execution-id "$UNHEALTHY_ID" \
  > "$EVIDENCE/04-unhealthy-health.json"
[ "$UNHEALTHY_STATUS" = Failed ] || fail "unhealthy fleet health: expected Failed, got $UNHEALTHY_STATUS"
for region in $REGIONS; do
  CHILD=$(child_execution "$UNHEALTHY_ID" "$region")
  [ -n "$CHILD" ] && [ "$CHILD" != None ] || fail "no child execution for $UNHEALTHY_ID in $region"
  aws ssm get-automation-execution \
    --region "$region" --automation-execution-id "$CHILD" \
    > "$EVIDENCE/04-unhealthy-health-$region.json"
done
UNHEALTHY_CENTRAL=$(aws ssm get-automation-execution \
  --region "$CENTRAL" --automation-execution-id "$(child_execution "$UNHEALTHY_ID" "$CENTRAL")" \
  --query AutomationExecution.AutomationExecutionStatus --output text)
UNHEALTHY_TARGET=$(aws ssm get-automation-execution \
  --region "$TARGET" --automation-execution-id "$(child_execution "$UNHEALTHY_ID" "$TARGET")" \
  --query AutomationExecution.AutomationExecutionStatus --output text)
[ "$UNHEALTHY_CENTRAL" = Success ] || fail "central connector unexpectedly unhealthy"
[ "$UNHEALTHY_TARGET" = Failed ] || fail "target connector did not report unhealthy (got $UNHEALTHY_TARGET)"
echo "unhealthy fleet health: $UNHEALTHY_STATUS ($TARGET failed, $CENTRAL healthy)"

echo "=== 5. Central replacement of the unhealthy connector (central, parameter-free) ==="

REPLACE_ID=$(aws ssm start-automation-execution \
  --region "$CENTRAL" \
  --document-name ZTNA-ReplaceUnhealthy \
  --query AutomationExecutionId \
  --output text) || fail "ZTNA-ReplaceUnhealthy did not start"
echo "execution: $REPLACE_ID"
REPLACE_STATUS=$(wait_execution "$REPLACE_ID")
aws ssm get-automation-execution \
  --region "$CENTRAL" --automation-execution-id "$REPLACE_ID" \
  > "$EVIDENCE/05-replace-unhealthy.json"
[ "$REPLACE_STATUS" = Success ] || fail "replacement: expected Success, got $REPLACE_STATUS"
for region in $REGIONS; do
  CHILD=$(child_execution "$REPLACE_ID" "$region")
  [ -n "$CHILD" ] && [ "$CHILD" != None ] || fail "no child execution for $REPLACE_ID in $region"
  aws ssm get-automation-execution \
    --region "$region" --automation-execution-id "$CHILD" \
    > "$EVIDENCE/05-replace-child-$region.json"
done

REPLACE_CHILD=$(child_execution "$REPLACE_ID" "$TARGET")
OLD_ID=$(aws ssm get-automation-execution \
  --region "$TARGET" --automation-execution-id "$REPLACE_CHILD" \
  --query 'AutomationExecution.Outputs."IdentifyAndReplace.OldInstanceIds"[0]' --output text)
NEW_ID=$(aws ssm get-automation-execution \
  --region "$TARGET" --automation-execution-id "$REPLACE_CHILD" \
  --query 'AutomationExecution.Outputs."IdentifyAndReplace.NewInstanceIds"[0]' --output text)
REPLACE_RESULT=$(aws ssm get-automation-execution \
  --region "$TARGET" --automation-execution-id "$REPLACE_CHILD" \
  --query 'AutomationExecution.Outputs."IdentifyAndReplace.Status"[0]' --output text)
CENTRAL_RESULT=$(aws ssm get-automation-execution \
  --region "$CENTRAL" --automation-execution-id "$(child_execution "$REPLACE_ID" "$CENTRAL")" \
  --query 'AutomationExecution.Outputs."IdentifyAndReplace.Status"[0]' --output text)

[ -n "$OLD_ID" ] && [ "$OLD_ID" != None ] || fail "replacement reported no unhealthy instance"
[ -n "$NEW_ID" ] && [ "$NEW_ID" != None ] || fail "replacement reported no new instance"
[ "$OLD_ID" != "$NEW_ID" ] || fail "replacement did not change the instance ID"
[ "$OLD_ID" = "$TARGET_INSTANCE" ] || fail "replacement acted on $OLD_ID, expected the stopped connector $TARGET_INSTANCE"
[ "$REPLACE_RESULT" = Success ] || fail "replacement result: expected Success, got $REPLACE_RESULT"
[ "$CENTRAL_RESULT" = AllHealthy ] || fail "central replacement child: expected AllHealthy, got $CENTRAL_RESULT"
echo "replaced $OLD_ID with $NEW_ID ($TARGET)"

echo "=== 6. Verify the replacement ==="

NEW_COUNT=$(aws ec2 describe-instances \
  --region "$TARGET" --instance-ids "$NEW_ID" \
  --filters 'Name=instance-state-name,Values=running' \
  --query 'length(Reservations[].Instances[])' \
  --output text)
[ "$NEW_COUNT" = 1 ] || fail "new instance $NEW_ID is not running"

aws ec2 describe-instances \
  --region "$TARGET" --instance-ids "$NEW_ID" \
  > "$EVIDENCE/06-post-replace-$TARGET.json"

PING=$(aws ssm describe-instance-information \
  --region "$TARGET" \
  --filters "Key=InstanceIds,Values=$NEW_ID" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text)
[ "$PING" = Online ] || fail "new instance $NEW_ID is not SSM-managed (PingStatus: $PING)"

[ "$(instance_tag "$TARGET" "$NEW_ID" ConnectorGroup)" = "production-$TARGET" ] \
  || fail "new instance $NEW_ID lacks the ConnectorGroup tag"

CENTRAL_AFTER=$(aws ec2 describe-instances \
  --region "$CENTRAL" \
  --filters 'Name=tag:Component,Values=Connector' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)
[ "$CENTRAL_AFTER" = "$CENTRAL_INSTANCE" ] || fail "central connector changed: $CENTRAL_INSTANCE -> $CENTRAL_AFTER"

TARGET_AFTER=$(aws ec2 describe-instances \
  --region "$TARGET" \
  --filters 'Name=tag:Component,Values=Connector' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)
[ "$TARGET_AFTER" = "$NEW_ID" ] || fail "target connector is $TARGET_AFTER, expected $NEW_ID"
echo "new connector $NEW_ID is running, SSM Online, only $OLD_ID -> $NEW_ID changed"

echo "=== 7. Central controlled restart (central, parameter-free) ==="

RESTART_ID=$(aws ssm start-automation-execution \
  --region "$CENTRAL" \
  --document-name ZTNA-ControlledRestart \
  --query AutomationExecutionId \
  --output text) || fail "ZTNA-ControlledRestart did not start"
echo "execution: $RESTART_ID"
RESTART_STATUS=$(wait_execution "$RESTART_ID")
aws ssm get-automation-execution \
  --region "$CENTRAL" --automation-execution-id "$RESTART_ID" \
  > "$EVIDENCE/07-controlled-restart.json"
[ "$RESTART_STATUS" = Success ] || fail "controlled restart: expected Success, got $RESTART_STATUS"

for region in $REGIONS; do
  CHILD=$(child_execution "$RESTART_ID" "$region")
  [ -n "$CHILD" ] && [ "$CHILD" != None ] || fail "no child execution for $RESTART_ID in $region"
  aws ssm get-automation-execution \
    --region "$region" --automation-execution-id "$CHILD" \
    > "$EVIDENCE/07-controlled-restart-$region.json"

  VERIFY_CMD=$(aws ssm describe-automation-step-executions \
    --region "$region" --automation-execution-id "$CHILD" \
    --query 'StepExecutions[?StepName==`VerifyRestart`] | [0].Outputs.CommandId' \
    --output text)
  [ -n "$VERIFY_CMD" ] && [ "$VERIFY_CMD" != None ] || fail "no VerifyRestart command in $region"

  VERIFY_INST=$(aws ssm list-command-invocations \
    --region "$region" --command-id "$VERIFY_CMD" --details \
    --query 'CommandInvocations[].InstanceId' \
    --output text)
  [ -n "$VERIFY_INST" ] && [ "$VERIFY_INST" != None ] || fail "no VerifyRestart target in $region"

  aws ssm get-command-invocation \
    --region "$region" --command-id "$VERIFY_CMD" --instance-id "$VERIFY_INST" \
    > "$EVIDENCE/07-restart-verify-$region.json"

  INV_STATUS=$(aws ssm get-command-invocation \
    --region "$region" --command-id "$VERIFY_CMD" --instance-id "$VERIFY_INST" \
    --query Status --output text)
  [ "$INV_STATUS" = Success ] || fail "VerifyRestart on $VERIFY_INST ($region): expected Success, got $INV_STATUS"

  BEFORE=$(aws ssm get-command-invocation \
    --region "$region" --command-id "$VERIFY_CMD" --instance-id "$VERIFY_INST" \
    --query StandardOutputContent --output text | sed -n 's/^before: //p')
  AFTER=$(aws ssm get-command-invocation \
    --region "$region" --command-id "$VERIFY_CMD" --instance-id "$VERIFY_INST" \
    --query StandardOutputContent --output text | sed -n 's/^after:  //p')

  [ -n "$BEFORE" ] && [ -n "$AFTER" ] || fail "no service start evidence in $region"
  [ "$BEFORE" != "$AFTER" ] || fail "restart did not change the service start in $region"
  echo "$region: $VERIFY_INST service start $BEFORE -> $AFTER"
done

echo "=== 8. Final fleet health (central, parameter-free) ==="

FINAL_ID=$(aws ssm start-automation-execution \
  --region "$CENTRAL" \
  --document-name ZTNA-HealthCheck \
  --query AutomationExecutionId \
  --output text) || fail "ZTNA-HealthCheck did not start"
echo "execution: $FINAL_ID"
FINAL_STATUS=$(wait_execution "$FINAL_ID")
aws ssm get-automation-execution \
  --region "$CENTRAL" --automation-execution-id "$FINAL_ID" \
  > "$EVIDENCE/08-final-health.json"
[ "$FINAL_STATUS" = Success ] || fail "final fleet health: expected Success, got $FINAL_STATUS"
for region in $REGIONS; do
  CHILD=$(child_execution "$FINAL_ID" "$region")
  [ -n "$CHILD" ] && [ "$CHILD" != None ] || fail "no child execution for $FINAL_ID in $region"
  aws ssm get-automation-execution \
    --region "$region" --automation-execution-id "$CHILD" \
    > "$EVIDENCE/08-final-health-$region.json"
done
echo "final fleet health: $FINAL_STATUS"

echo
echo "Validation complete. Evidence: $EVIDENCE/"
