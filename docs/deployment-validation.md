# Deployment Validation

## Deployment record

- **Deployment date:** August 22, 2026
- **AWS Region:** `eu-north-1`
- **Final CloudFormation status:** `CREATE_COMPLETE`
- **Live verification:** All checks passed
- **GitHub Actions CI:** Passed

## Verified architecture

The live stack and read-only verification confirmed:

- Six subnets across two Availability Zones
- Public, private application, and isolated database tiers
- Public IPv4 assignment disabled on every subnet
- Internet route present only on public route tables
- No NAT routes in the private tiers
- S3 Gateway VPC Endpoint attached only to application route tables
- Tiered security-group trust chain from internet HTTPS to the load balancer tier, from the load balancer tier to the application tier, and from the application tier to the database tier on PostgreSQL 5432
- Active VPC Flow Logs
- CloudWatch Logs retention set to seven days
- No NAT Gateway, Elastic IP, EC2 instance, or RDS instance

## Issues resolved during deployment

### CloudWatch Flow Logs destination options

The initial deployment issue was caused by `DestinationOptions` being unsupported for `cloud-watch-logs` Flow Log destinations. The unsupported property was removed while retaining the CloudWatch Logs destination, custom log format, and required delivery settings.

### CI credential-scan false positive

The credential scanner initially matched its own pattern definition in the GitHub Actions workflow. The scanner was corrected to exclude only the workflow from content scanning while continuing to scan repository source, documentation, scripts, tests, and infrastructure files.

## Cleanup and reproducibility

The live stack may be deleted after validation to avoid ongoing CloudWatch Logs and VPC Flow Logs charges. The infrastructure remains reproducible from `infrastructure/network.yaml`, so the stack can be recreated for future validation without retaining the live resources continuously.
