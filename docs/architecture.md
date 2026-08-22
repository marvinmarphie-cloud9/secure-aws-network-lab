# Secure AWS Network Architecture Lab

## Scope

This lab provisions a secure, compute-free network foundation in one AWS Region. It selects the first two Availability Zones returned by AWS at deployment time and creates two subnets in each tier: public, private application, and isolated database.

The security groups model the intended future workload boundaries. They do not deploy a load balancer, application instances, containers, or a database. The public subnets are reserved for a future internet-facing load balancer; the application and database subnets have no internet route.

## Traffic design

- The public route table has the only default route, through the Internet Gateway. The Internet Gateway is attached to the VPC but no public IPv4 resource is deployed.
- The private application route table has no internet route and is associated with the S3 Gateway VPC Endpoint. S3 traffic stays on the AWS network without a NAT Gateway.
- The isolated database route table has no routes beyond the VPC-local route automatically provided by AWS.
- The load-balancer security group allows TCP 443 from `0.0.0.0/0` for a future HTTPS listener.
- The application security group allows TCP 443 only from the load-balancer security group.
- The database security group allows PostgreSQL TCP 5432 only from the application security group.

## Observability and identity

VPC Flow Logs capture all traffic and publish to a CloudWatch Logs group retained for seven days. CloudWatch Logs encrypts log data at rest by default using service-managed AES-256 encryption. A customer-managed KMS key is intentionally excluded to avoid its recurring monthly key-storage charge. Customer-managed KMS encryption is a documented future enhancement for regulated environments requiring direct key-policy control. The Flow Logs IAM role grants only `logs:CreateLogStream` and `logs:PutLogEvents` to that log group. CloudWatch log streams require the scoped `${LogGroupArn}:*` suffix, which is the only wildcard resource in the role policy.

## Tagging

Named resources use `Project`, `Environment`, and `ManagedBy=CloudFormation` tags. Subnets and security groups also include a tier tag to make ownership and intended placement visible during review.

## Deliberate omissions

There is no NAT Gateway, Elastic IP, EC2 instance, database, load balancer, public IPv4 address allocation, or other compute workload. These omissions keep the lab focused on network controls and avoid silently creating workload or hourly processing costs.