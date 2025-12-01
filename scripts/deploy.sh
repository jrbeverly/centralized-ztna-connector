#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/templates/connector.yaml"

for REGION in ca-central-1 us-east-1; do
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters 'Name=tag:ZTNAConnector,Values=Enabled' \
    --query 'Vpcs[0].VpcId' \
    --output text)

  SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters 'Name=tag:ZTNAConnector,Values=Enabled' 'Name=tag:Environment,Values=Production' \
    --query 'Subnets[0].SubnetId' \
    --output text)

  SECRET_ARN=$(aws secretsmanager describe-secret \
    --region "$REGION" \
    --secret-id ztna/bootstrap-credential \
    --query ARN \
    --output text)

  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "ztna-connector-$REGION" \
    --template-file "$TEMPLATE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      "VpcId=$VPC_ID" \
      "SubnetId=$SUBNET_ID" \
      "BootstrapSecretArn=$SECRET_ARN" \
      "ConnectorGroup=production-$REGION"
done
