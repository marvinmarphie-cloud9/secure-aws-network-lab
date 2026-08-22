[CmdletBinding()]
param(
    [Parameter()]
    [string]$StackName = "secure-aws-network-lab",

    [Parameter()]
    [string]$Profile = "secure-cloud-resume",

    [Parameter()]
    [string]$Region = "eu-north-1"
)

$ErrorActionPreference = "Stop"
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $awsArguments = @($Arguments + @("--profile", $Profile, "--region", $Region, "--output", "json", "--no-cli-pager"))
    $output = & aws @awsArguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI read-only command failed: $($Arguments[0]) $($Arguments[1])"
    }

    if ([string]::IsNullOrWhiteSpace(($output -join ""))) {
        return $null
    }

    return ($output -join [Environment]::NewLine | ConvertFrom-Json)
}

function Invoke-VerificationCheck {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Check
    )

    try {
        & $Check
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    catch {
        $failures.Add($Name)
        Write-Host "FAIL: $Name" -ForegroundColor Red
        Write-Host "ERROR: Stage '$Name': $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

function Get-StackResource {
    param(
        [Parameter(Mandatory)]
        [object[]]$Resources,

        [Parameter(Mandatory)]
        [string]$LogicalResourceId
    )

    $resource = @($Resources | Where-Object LogicalResourceId -eq $LogicalResourceId)
    if ($resource.Count -ne 1 -or [string]::IsNullOrWhiteSpace($resource[0].PhysicalResourceId)) {
        throw "Required stack resource was not discovered"
    }

    return $resource[0]
}

function Get-Route {
    param(
        [Parameter(Mandatory)]
        [object]$RouteTable,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    return @($RouteTable.Routes | Where-Object DestinationCidrBlock -eq $Destination)
}

function Get-SecurityGroup {
    param(
        [Parameter(Mandatory)]
        [object[]]$SecurityGroups,

        [Parameter(Mandatory)]
        [string]$GroupId
    )

    $group = @($SecurityGroups | Where-Object GroupId -eq $GroupId)
    if ($group.Count -ne 1) {
        throw "Required security group was not discovered"
    }

    return $group[0]
}

Write-Host "Verifying stack '$StackName' in region '$Region' using profile '$Profile'..."

$currentStage = "CloudFormation stack discovery"
try {
    $stackResponse = Invoke-AwsJson -Arguments @(
        "cloudformation", "describe-stacks", "--stack-name", $StackName
    )
    $stack = @($stackResponse.Stacks)[0]
    if ($null -eq $stack) {
        throw "CloudFormation stack was not found"
    }

    $currentStage = "CloudFormation resource ID discovery"
    $stackResourcesResponse = Invoke-AwsJson -Arguments @(
        "cloudformation", "list-stack-resources", "--stack-name", $StackName
    )
    $stackResources = @($stackResourcesResponse.StackResourceSummaries)

    $resourceByLogicalId = @{}
    foreach ($resource in $stackResources) {
        $resourceByLogicalId[$resource.LogicalResourceId] = $resource
    }

    $vpcResource = Get-StackResource -Resources $stackResources -LogicalResourceId "NetworkVpc"
    $publicRouteTableResource = Get-StackResource -Resources $stackResources -LogicalResourceId "PublicRouteTable"
    $applicationRouteTableResource = Get-StackResource -Resources $stackResources -LogicalResourceId "ApplicationRouteTable"
    $databaseRouteTableResource = Get-StackResource -Resources $stackResources -LogicalResourceId "DatabaseRouteTable"
    $endpointResource = Get-StackResource -Resources $stackResources -LogicalResourceId "S3GatewayEndpoint"
    $flowLogResource = Get-StackResource -Resources $stackResources -LogicalResourceId "VpcFlowLog"
    $logGroupResource = Get-StackResource -Resources $stackResources -LogicalResourceId "FlowLogsLogGroup"
    $loadBalancerSecurityGroupResource = Get-StackResource -Resources $stackResources -LogicalResourceId "LoadBalancerSecurityGroup"
    $applicationSecurityGroupResource = Get-StackResource -Resources $stackResources -LogicalResourceId "ApplicationSecurityGroup"
    $databaseSecurityGroupResource = Get-StackResource -Resources $stackResources -LogicalResourceId "DatabaseSecurityGroup"

    $subnetResources = @($stackResources | Where-Object ResourceType -eq "AWS::EC2::Subnet")
    $routeTableResources = @($stackResources | Where-Object ResourceType -eq "AWS::EC2::RouteTable")

    Invoke-VerificationCheck -Name "CloudFormation stack completed" -Check {
        if ($stack.StackStatus -notin @("CREATE_COMPLETE", "UPDATE_COMPLETE")) {
            throw "Unexpected stack status"
        }
    }

    Invoke-VerificationCheck -Name "Exactly six subnets belong to the stack" -Check {
        if ($subnetResources.Count -ne 6) {
            throw "Unexpected subnet count"
        }
    }

    $subnetIds = @($subnetResources | Select-Object -ExpandProperty PhysicalResourceId)
    $subnetArguments = @("ec2", "describe-subnets", "--subnet-ids") + $subnetIds
    $currentStage = "subnet attribute discovery"
    $subnetsResponse = Invoke-AwsJson -Arguments $subnetArguments
    $subnets = @($subnetsResponse.Subnets)

    Invoke-VerificationCheck -Name "All six subnets disable public IPv4 assignment" -Check {
        if ($subnets.Count -ne 6 -or @($subnets | Where-Object MapPublicIpOnLaunch).Count -ne 0) {
            throw "A subnet enables MapPublicIpOnLaunch"
        }
    }

    $routeTableIds = @($routeTableResources | Select-Object -ExpandProperty PhysicalResourceId)
    $routeTableArguments = @("ec2", "describe-route-tables", "--route-table-ids") + $routeTableIds
    $currentStage = "route table discovery"
    $routeTablesResponse = Invoke-AwsJson -Arguments $routeTableArguments
    $routeTables = @($routeTablesResponse.RouteTables)
    $publicRouteTable = @($routeTables | Where-Object RouteTableId -eq $publicRouteTableResource.PhysicalResourceId)[0]
    $applicationRouteTable = @($routeTables | Where-Object RouteTableId -eq $applicationRouteTableResource.PhysicalResourceId)[0]
    $databaseRouteTable = @($routeTables | Where-Object RouteTableId -eq $databaseRouteTableResource.PhysicalResourceId)[0]

    Invoke-VerificationCheck -Name "Only the public route table has an Internet Gateway default route" -Check {
        $publicInternetRoutes = @(Get-Route -RouteTable $publicRouteTable -Destination "0.0.0.0/0" | Where-Object GatewayId -like "igw-*")
        $privateInternetRoutes = @(
            (Get-Route -RouteTable $applicationRouteTable -Destination "0.0.0.0/0") +
            (Get-Route -RouteTable $databaseRouteTable -Destination "0.0.0.0/0") |
            Where-Object GatewayId -like "igw-*"
        )
        if ($publicInternetRoutes.Count -ne 1 -or $privateInternetRoutes.Count -ne 0) {
            throw "Internet Gateway route placement is incorrect"
        }
    }

    Invoke-VerificationCheck -Name "Application and database route tables have no internet or NAT route" -Check {
        $privateRoutes = @($applicationRouteTable.Routes + $databaseRouteTable.Routes)
        if (@($privateRoutes | Where-Object { $_.DestinationCidrBlock -eq "0.0.0.0/0" -or $_.NatGatewayId }).Count -ne 0) {
            throw "A private route table has an internet or NAT route"
        }
    }

    Invoke-VerificationCheck -Name "No NAT Gateway, Elastic IP, EC2 instance, or RDS instance belongs to the stack" -Check {
        $disallowedTypes = @(
            "AWS::EC2::NatGateway",
            "AWS::EC2::EIP",
            "AWS::EC2::Instance",
            "AWS::RDS::DBInstance"
        )
        if (@($stackResources | Where-Object ResourceType -in $disallowedTypes).Count -ne 0) {
            throw "A disallowed workload resource belongs to the stack"
        }
    }

    $currentStage = "S3 endpoint discovery"
    $endpointResponse = Invoke-AwsJson -Arguments @(
        "ec2", "describe-vpc-endpoints", "--vpc-endpoint-ids", $endpointResource.PhysicalResourceId
    )
    $endpoint = @($endpointResponse.VpcEndpoints)[0]
    Invoke-VerificationCheck -Name "S3 Gateway VPC Endpoint is available and application-only" -Check {
        if ($endpoint.State -ne "available" -or $endpoint.VpcEndpointType -ne "Gateway") {
            throw "S3 endpoint is not an available Gateway endpoint"
        }
        $expectedRouteTables = @($applicationRouteTableResource.PhysicalResourceId)
        $actualRouteTables = @($endpoint.RouteTableIds)
        if ($actualRouteTables.Count -ne 1 -or $actualRouteTables[0] -ne $expectedRouteTables[0]) {
            throw "S3 endpoint is attached to an unexpected route table"
        }
    }

    $currentStage = "VPC Flow Log discovery"
    $flowLogsResponse = Invoke-AwsJson -Arguments @(
        "ec2", "describe-flow-logs", "--filter", "Name=resource-id,Values=$($vpcResource.PhysicalResourceId)"
    )
    $flowLog = @($flowLogsResponse.FlowLogs | Where-Object FlowLogId -eq $flowLogResource.PhysicalResourceId)[0]
    Invoke-VerificationCheck -Name "VPC Flow Log delivery is active" -Check {
        if ($null -eq $flowLog -or $flowLog.DeliverLogsStatus -notin @("SUCCESS", "ACTIVE")) {
            throw "Unexpected Flow Log delivery status"
        }
    }

    $currentStage = "CloudWatch log group discovery"
    $logGroupResponse = Invoke-AwsJson -Arguments @(
        "logs", "describe-log-groups", "--log-group-name-prefix", $logGroupResource.PhysicalResourceId
    )
    $logGroup = @($logGroupResponse.logGroups | Where-Object logGroupName -eq $logGroupResource.PhysicalResourceId)[0]
    Invoke-VerificationCheck -Name "CloudWatch log group exists with seven-day retention" -Check {
        if ($null -eq $logGroup -or $logGroup.retentionInDays -ne 7) {
            throw "Log group is missing or has unexpected retention"
        }
    }

    $currentStage = "security-group discovery"
    $securityGroupIds = @(
        $loadBalancerSecurityGroupResource.PhysicalResourceId,
        $applicationSecurityGroupResource.PhysicalResourceId,
        $databaseSecurityGroupResource.PhysicalResourceId
    )
    $securityGroupArguments = @("ec2", "describe-security-groups", "--group-ids") + $securityGroupIds
    $securityGroupResponse = Invoke-AwsJson -Arguments $securityGroupArguments
    $securityGroups = @($securityGroupResponse.SecurityGroups)
    $currentStage = "security-group trust-chain discovery"
    $loadBalancerSecurityGroup = Get-SecurityGroup -SecurityGroups $securityGroups -GroupId $loadBalancerSecurityGroupResource.PhysicalResourceId
    $applicationSecurityGroup = Get-SecurityGroup -SecurityGroups $securityGroups -GroupId $applicationSecurityGroupResource.PhysicalResourceId
    $databaseSecurityGroup = Get-SecurityGroup -SecurityGroups $securityGroups -GroupId $databaseSecurityGroupResource.PhysicalResourceId

    Invoke-VerificationCheck -Name "Security-group ingress follows the load balancer to application trust chain" -Check {
        $httpsInternetRules = @($loadBalancerSecurityGroup.IpPermissions | Where-Object {
            $_.IpProtocol -eq "tcp" -and $_.FromPort -eq 443 -and $_.ToPort -eq 443 -and
            @($_.IpRanges | Where-Object CidrIp -eq "0.0.0.0/0").Count -gt 0
        })
        $applicationRules = @($applicationSecurityGroup.IpPermissions | Where-Object {
            $_.IpProtocol -eq "tcp" -and $_.FromPort -eq 443 -and $_.ToPort -eq 443 -and
            @($_.UserIdGroupPairs | Where-Object GroupId -eq $loadBalancerSecurityGroup.GroupId).Count -gt 0
        })
        if ($httpsInternetRules.Count -eq 0 -or $applicationRules.Count -eq 0) {
            throw "Load balancer to application ingress is incomplete"
        }
    }

    Invoke-VerificationCheck -Name "Database security group allows only application PostgreSQL ingress" -Check {
        $postgresRules = @($databaseSecurityGroup.IpPermissions | Where-Object {
            $_.IpProtocol -eq "tcp" -and $_.FromPort -eq 5432 -and $_.ToPort -eq 5432 -and
            @($_.UserIdGroupPairs | Where-Object GroupId -eq $applicationSecurityGroup.GroupId).Count -gt 0
        })
        $publicDatabaseRules = @($databaseSecurityGroup.IpPermissions | Where-Object {
            @($_.IpRanges | Where-Object CidrIp -eq "0.0.0.0/0").Count -gt 0
        })
        if ($postgresRules.Count -eq 0 -or $publicDatabaseRules.Count -ne 0) {
            throw "Database ingress trust boundary is incorrect"
        }
    }
}
catch {
    $failures.Add("Deployment data discovery")
    Write-Host "FAIL: Deployment data discovery" -ForegroundColor Red
    Write-Host "ERROR: Stage '$currentStage': $($_.Exception.Message)" -ForegroundColor DarkRed
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "Verification summary: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "Verification summary: FAIL ($($failures.Count) check(s))" -ForegroundColor Red
exit 1
