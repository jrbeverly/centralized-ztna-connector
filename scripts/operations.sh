#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/templates/operations.yaml"

for REGION in ca-central-1 us-east-1; do
  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "ztna-operations-$REGION" \
    --template-file "$TEMPLATE" \
    --capabilities CAPABILITY_NAMED_IAM
done
