# Centralized ZTNA Connector

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

> [!WARNING]
> This experiment is effectively abandoned. The generated material is retained primarily as a research artifact.

Proves cross-Region SSM Automation for ZTNA connector operations from a single disposable AWS account.

## Topology

One account, two Regions. `ca-central-1` is the operations hub: SSM Automation documents are registered here and cross-Region executions originate here. `us-east-1` is the target Region that receives connector stacks.

Multi-account operation and real ZTNA vendor integration are explicitly deferred.

| Constant                  | Value                                                                   |
| ------------------------- | ----------------------------------------------------------------------- |
| Central Region            | `ca-central-1`                                                          |
| Target Region             | `us-east-1`                                                             |
| VPC eligibility tag       | `ZTNAConnector=Enabled`                                                 |
| Subnet eligibility tags   | `ZTNAConnector=Enabled`, `Environment=Production`                       |
| Connector stack — central | `ztna-connector-ca-central-1`                                           |
| Connector stack — target  | `ztna-connector-us-east-1`                                              |
| Bootstrap secret name     | `ztna/bootstrap-credential`                                             |
| Mock service name         | `ztna-mock`                                                             |
| AMI parameter             | `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` |

**Connector inventory tags** applied by each stack to its EC2 instance:

| Tag              | Value                                               |
| ---------------- | --------------------------------------------------- |
| `ManagedBy`      | `ZTNA`                                              |
| `Component`      | `Connector`                                         |
| `Environment`    | `Production`                                        |
| `ConnectorGroup` | `production-ca-central-1` or `production-us-east-1` |

**Operator-facing Automation documents** registered in `ca-central-1`. No operator-supplied targeting parameters.

| Document                 | Operation                                                                                                             |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `ZTNA-HealthCheck`       | Report SSM reachability and mock service status for every tagged connector                                            |
| `ZTNA-ReplaceUnhealthy`  | Terminate and re-create connectors absent from SSM managed-instance inventory                                         |
| `ZTNA-ControlledRestart` | Restart the mock service on every production-tagged connector at fixed concurrency, then verify the restarted service |
