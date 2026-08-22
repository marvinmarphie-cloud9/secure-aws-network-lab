# Secure AWS Network Architecture Lab

## Purpose

This repository is a reviewable CloudFormation lab for a secure, multi-tier AWS network foundation. It creates the network controls and observability needed before deploying workloads; it does not deploy compute, a load balancer, or a database.

## Planned architecture

The template selects two Availability Zones dynamically and creates six subnets: two public subnets for a future load balancer, two private application subnets, and two isolated database subnets. Only the public route table has an Internet Gateway default route. Application subnets can reach Amazon S3 through a Gateway VPC Endpoint, while application and database route tables have no internet routes. There is no NAT Gateway.

## Security controls

- VPC DNS support and DNS hostnames are enabled.
- Security groups model a one-way workload chain: public HTTPS to the future load balancer, load balancer to application, and application to PostgreSQL database.
- VPC Flow Logs capture all traffic in a CloudWatch log group with seven-day retention. CloudWatch Logs encrypts log data at rest by default using service-managed AES-256 encryption.
- A customer-managed KMS key is intentionally excluded to avoid its recurring monthly key-storage charge. Customer-managed KMS encryption is a documented future enhancement for regulated environments requiring direct key-policy control.
- Flow Logs use a least-privilege publishing role. The scoped log-stream suffix wildcard is required for log streams and documented in `docs/architecture.md`.
- No EC2 instances, Elastic IP addresses, public IPv4 resources, or database resources are created.
- Project, environment, tier, and managed-by tags support ownership and review.

## Repository structure

```text
infrastructure/network.yaml     CloudFormation network foundation
scripts/verify-deployment.ps1   Read-only post-deployment verification
docs/architecture.md             Detailed traffic and security design
tests/test_network_template.py   Offline architecture assertions
.github/workflows/ci.yml         YAML, lint, test, and security validation
```

## Post-deployment verification

After deploying the stack manually, run the read-only Windows PowerShell verification script from the repository root:

```powershell
.\scripts\verify-deployment.ps1
```

The defaults verify stack `secure-aws-network-lab` with AWS CLI profile `secure-cloud-resume` in `eu-north-1`. Override them when needed:

```powershell
.\scripts\verify-deployment.ps1 -StackName my-stack -Profile my-profile -Region eu-west-1
```

The script discovers physical resource IDs from CloudFormation, prints a PASS/FAIL summary, and exits with code `1` if any check fails. It does not create, update, or delete AWS resources.

## Deployment Validation

The successful August 22, 2026 deployment and live verification results are recorded in [docs/deployment-validation.md](docs/deployment-validation.md).

## Deployment warning

This repository is intentionally not deployed by CI. Review the template, region, parameters, IAM implications, and expected costs before running CloudFormation yourself. The template creates AWS resources and requires suitable permissions in the target account.

## Cost considerations

The VPC, subnets, route tables, security groups, Internet Gateway, and S3 Gateway Endpoint generally have no hourly charge, but AWS pricing can change. VPC Flow Logs and CloudWatch Logs may incur small charges based on traffic volume and retained log data. The customer-managed KMS key is intentionally excluded, avoiding its recurring monthly key-storage charge. No NAT Gateway, compute, or database resources are included, avoiding their larger ongoing costs.

## Cleanup

If you deploy the stack manually, delete the CloudFormation stack after the lab. Confirm that the Flow Logs log group is removed according to your retention and deletion policy requirements, then verify in the AWS console or CLI that no lab resources remain. Do not delete shared resources outside this stack.

## Troubleshooting

An earlier deployment failed because `DestinationOptions` is not supported when an `AWS::EC2::FlowLog` uses `LogDestinationType: cloud-watch-logs`. The fix is to remove the entire `DestinationOptions` block while retaining the CloudWatch destination, log group, custom `LogFormat`, and other Flow Log properties. The template does not deploy this unsupported property.
