# Centralized ZTNA Connector Operations — Vision Design

## 1. Objective

Provide a centrally operated, AWS-native platform for deploying and managing ZTNA connectors across many AWS accounts, Regions, and VPCs.

The design should make connector infrastructure effectively disposable and operationally inexpensive to manage.

Key goals:

- One or more connectors can be deployed into every eligible VPC.
- Deployment requires no application-team involvement.
- VPCs and subnets are selected using standardized AWS tags.
- Connectors bootstrap automatically using centrally controlled credentials.
- Operators never need to switch AWS accounts or Regions.
- Routine operations require no manual entry of account IDs, instance IDs, tags, or other parameters.
- Operational actions are predefined and exposed as purpose-built SSM Automation runbooks.
- The management path has minimal dependencies beyond AWS's own control plane.

---

## 2. Architecture

```text
                 AWS ORGANIZATION
                       │
                       │
              Operations Account
        ┌─────────────────────────────┐
        │                             │
        │ Systems Manager            │
        │                             │
        │ Approved Automation        │
        │ Runbooks                   │
        │                             │
        │ • Health Check             │
        │ • Restart                  │
        │ • Replace                  │
        │ • Upgrade                  │
        │ • Re-enroll                │
        │ • Diagnostics              │
        │                             │
        └──────────────┬──────────────┘
                       │
              cross-account /
              cross-Region SSM
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
     Account A      Account B      Account C
     Region 1       Region 2       Region 1
        │              │              │
       VPC            VPC            VPC
        │              │              │
     Connector      Connector      Connector
       EC2             EC2            EC2
```

The Operations Account is the central point for fleet operations.

Individual connectors remain resources of their application accounts and VPCs.

---

## 3. Connector Deployment

A standard CloudFormation stack defines a connector.

The stack contains only the infrastructure necessary to operate the connector:

```text
Connector Stack
│
├── EC2 instance
├── IAM instance profile
├── Security groups
├── SSM Agent
├── Connector software
├── Bootstrap configuration
└── Standardized tags
```

The same stack is deployed throughout the AWS Organization using centralized automation such as CloudFormation StackSets.

### VPC and Subnet Selection

Deployment eligibility is driven by tags.

Example:

```text
VPC:
  ZTNAConnector = Enabled

Subnet:
  ZTNAConnector = Enabled
  Environment   = Production
```

The deployment process discovers eligible VPCs/subnets and places the connector accordingly.

Application teams do not provision or configure connectors.

---

## 4. Connector Bootstrap

Connector instances bootstrap themselves when created.

Conceptually:

```text
EC2 starts
   ↓
retrieve bootstrap credential
   ↓
install/start connector
   ↓
register with ZTNA control plane
   ↓
register with SSM
   ↓
healthy
```

Credentials are made available through the organization's approved secret-distribution mechanism.

No credentials are embedded in CloudFormation templates, AMIs, or user data.

A replaced connector should be able to bootstrap without operator intervention.

---

## 5. Resource Identity

Every connector receives standardized tags.

For example:

```text
ManagedBy       = ZTNA
Component       = Connector
Environment     = Production
AccountClass    = Application
VPC             = vpc-xxxxxxxx
ConnectorGroup  = production-canada
```

These tags form the common inventory and targeting model.

Operators should not normally work with EC2 instance IDs.

---

## 6. Operations Control Plane

AWS Systems Manager Automation is the primary operations engine.

Systems Manager is configured for centralized, cross-account and cross-Region operation from the Operations Account.

The important design principle is:

> Operators select an operation, not its implementation parameters.

Instead of maintaining one generic runbook requiring an operator to provide targets and configuration, the platform publishes purpose-built runbooks.

For example:

```text
ZTNA-HealthCheck-All

ZTNA-Restart-Production
ZTNA-Restart-NonProduction

ZTNA-RollingRestart-Production

ZTNA-Replace-Unhealthy

ZTNA-Upgrade-Production
ZTNA-Upgrade-NonProduction

ZTNA-ReEnroll-Unhealthy

ZTNA-CollectDiagnostics
```

The runbooks contain the appropriate targeting and safety configuration.

---

## 7. Runbook Model

A runbook defines:

```text
WHAT
  Operation being performed

WHERE
  Accounts / OUs
  Regions
  Resource tags

HOW
  SSM commands/API operations

SAFETY
  Concurrency
  Failure threshold
  Verification
```

For example:

```text
ZTNA-RollingRestart-Production

Target:
  Component = Connector
  Environment = Production

Scope:
  Production AWS OUs
  Approved Regions

Concurrency:
  10%

Failure threshold:
  5%

Operation:
  Restart connector service

Verification:
  Confirm service healthy
```

Those values are maintained as code rather than entered by an operator.

---

## 8. Operator Experience

The AWS Systems Manager console is the initial user interface.

An operator performs:

```text
AWS Console
    ↓
Systems Manager
    ↓
Automation
    ↓
ZTNA-RollingRestart-Production
    ↓
Execute
```

There should be no requirement to enter:

- AWS account IDs
- Regions
- VPC IDs
- instance IDs
- tags
- concurrency
- failure thresholds
- shell commands

Where AWS requires parameters syntactically, safe values should be supplied as defaults wherever practical.

The objective is effectively:

> Find approved operation → review → execute.

---

## 9. Example: Replace an Unhealthy Connector

A replacement runbook could perform:

```text
Find connectors tagged:
  Component = Connector

        ↓

Determine unhealthy connectors

        ↓

Capture diagnostics

        ↓

Terminate/replace instance

        ↓

CloudFormation/ASG restores desired state

        ↓

Wait for SSM registration

        ↓

Wait for ZTNA registration

        ↓

Perform connectivity test

        ↓

Success / Failure
```

The connector is treated as disposable infrastructure rather than something an administrator repairs manually.

---

## 10. Permissions

Operators should be able to execute approved operations but not redefine them.

Conceptually:

```text
Platform Engineering
    │
    ├── Create/update ZTNA-* runbooks
    └── Define targeting/safety controls


Operations
    │
    └── Execute approved ZTNA-* runbooks
```

Operators should not require administrative access to the application accounts.

Cross-account execution roles provide the necessary permissions to SSM Automation.

---

## 11. Failure-Domain Principle

The operational control path should remain intentionally small:

```text
Operator
   ↓
AWS authentication
   ↓
Systems Manager
   ↓
SSM Automation
   ↓
SSM Agent
   ↓
Connector
```

A custom operational portal is intentionally excluded from the initial design.

This avoids making connector recovery dependent on additional components such as:

```text
CloudFront
Cognito
API Gateway
Lambda
DynamoDB
custom application code
```

If the ZTNA data plane itself is impaired, administrators can still operate the connectors through the AWS/SSM management plane.

---

## 12. Provisioning vs. Operations

The architecture deliberately separates two responsibilities.

### Provisioning Plane

```text
AWS Organizations
       +
CloudFormation / StackSets
       +
VPC/Subnet tags
       ↓
Connector exists
```

Responsible for desired infrastructure state.

### Operations Plane

```text
Systems Manager
       +
Automation Runbooks
       +
Resource tags
       ↓
Connector operated
```

Responsible for actions against the existing fleet.

The operations plane should not become a second provisioning system.

---

## 13. Design Principle

The overall operating model is:

```text
VPC exists
   ↓
Tags make it eligible
   ↓
Connector automatically deployed
   ↓
Connector automatically bootstraps
   ↓
SSM automatically manages it
   ↓
Central operator sees only
predefined fleet operations
```

The number of AWS accounts, Regions, VPCs, and connectors should have minimal effect on the amount of human operational work required.

Adding another 500 connectors should increase infrastructure consumption, but should not materially increase the administrative process required to operate the fleet.
