# Creation and several Describe/List APIs require wildcard resources. These are explicit
# service actions, restricted to the deployment region when regional. For stronger
# isolation, bootstrap each environment in its own AWS account (see docs/SECURITY.md).
locals {
  read_actions = [
    "ec2:Describe*", "elasticloadbalancing:Describe*", "ecs:Describe*", "ecs:List*",
    "application-autoscaling:Describe*", "application-autoscaling:ListTagsForResource",
    "cloudfront:Get*", "cloudfront:List*", "cloudfront:DescribeFunction",
    "cognito-idp:DescribeUserPool", "cognito-idp:DescribeUserPoolClient", "cognito-idp:DescribeUserPoolDomain",
    "cognito-idp:ListTagsForResource", "cognito-idp:GetUserPoolMfaConfig", "acm:DescribeCertificate", "acm:ListTagsForCertificate",
    "logs:DescribeLogGroups", "logs:DescribeMetricFilters", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
    "cloudwatch:DescribeAlarms", "cloudwatch:GetDashboard", "cloudwatch:ListTagsForResource",
    "wafv2:GetWebACL", "wafv2:GetWebACLForResource", "wafv2:ListResourcesForWebACL", "wafv2:ListTagsForResource",
    "wafv2:GetLoggingConfiguration", "tag:GetResources", "sns:ListTopics"
  ]
  network_write = [
    "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute", "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
    "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway", "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
    "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
    "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable", "ec2:ReplaceRouteTableAssociation",
    "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
    "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules",
    "ec2:CreateVpcEndpoint", "ec2:ModifyVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:CreateTags", "ec2:DeleteTags",
    "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs"
  ]
}
resource "aws_iam_policy" "read" {
  name   = "${var.project}-infra-describe"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = local.read_actions, Resource = "*" }] })
}
resource "aws_iam_role_policy_attachment" "plan_read" {
  for_each   = local.envs
  role       = aws_iam_role.plan[each.key].name
  policy_arn = aws_iam_policy.read.arn
}
resource "aws_iam_role_policy_attachment" "deploy_read" {
  for_each   = local.envs
  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.read.arn
}
resource "aws_iam_policy" "state_read" {
  for_each = local.envs
  name     = "${var.project}-state-read-${each.key}"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.state.arn,
    Condition = { StringLike = { "s3:prefix" = ["${each.key}/*", "${each.key}"] } } },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.state.arn}/${each.key}/terraform.tfstate" },
    { Effect = "Allow", Action = ["kms:Decrypt", "kms:DescribeKey"], Resource = aws_kms_key.state.arn },
    { Effect = "Allow", Action = ["s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:ListBucket"],
    Resource = "arn:aws:s3:::${var.project}-${each.key}-${local.account}-*" },
    { Effect = "Allow", Action = ["dynamodb:DescribeTable", "dynamodb:DescribeTimeToLive", "dynamodb:DescribeContinuousBackups", "dynamodb:ListTagsOfResource"],
    Resource = "arn:aws:dynamodb:${local.region}:${local.account}:table/${var.project}-${each.key}-chat" },
    { Effect = "Allow", Action = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"],
    Resource = "arn:aws:secretsmanager:${local.region}:${local.account}:secret:${var.project}-${each.key}/anthropic-*" },
    { Effect = "Allow", Action = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"],
    Resource = "arn:aws:iam::${local.account}:role/${var.project}-runtime-${each.key}-*" },
    { Effect = "Allow", Action = ["route53:GetHostedZone", "route53:ListResourceRecordSets"], Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}" },
    { Effect = "Allow", Action = ["route53:GetChange"], Resource = "arn:aws:route53:::change/*" },
    { Effect = "Allow", Action = ["sns:GetTopicAttributes", "sns:ListTagsForResource"], Resource = "arn:aws:sns:${local.region}:${local.account}:${var.project}-${each.key}-notifications" }
  ] })
}
resource "aws_iam_role_policy_attachment" "plan_state" {
  for_each   = local.envs
  role       = aws_iam_role.plan[each.key].name
  policy_arn = aws_iam_policy.state_read[each.key].arn
}
resource "aws_iam_role_policy_attachment" "deploy_state" {
  for_each   = local.envs
  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.state_read[each.key].arn
}
resource "aws_iam_policy" "network" {
  name = "${var.project}-infra-network"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = local.network_write, Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = local.region } } },
    { Effect = "Allow", Action = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:CreateListener", "elasticloadbalancing:ModifyListener", "elasticloadbalancing:DeleteListener", "elasticloadbalancing:CreateRule", "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:DeleteRule", "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"],
      Resource = ["arn:aws:elasticloadbalancing:${local.region}:${local.account}:loadbalancer/app/${var.project}-*/*",
        "arn:aws:elasticloadbalancing:${local.region}:${local.account}:targetgroup/${var.project}-*/*",
        "arn:aws:elasticloadbalancing:${local.region}:${local.account}:listener/app/${var.project}-*/*/*",
    "arn:aws:elasticloadbalancing:${local.region}:${local.account}:listener-rule/app/${var.project}-*/*/*/*"] },
    { Effect = "Allow", Action = ["acm:RequestCertificate", "acm:DeleteCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate"],
    Resource = "arn:aws:acm:${local.region}:${local.account}:certificate/*" },
    { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets"], Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}" },
    { Effect = "Allow", Action = ["cloudfront:CreateDistribution", "cloudfront:CreateDistributionWithTags", "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
      "cloudfront:CreateOriginAccessControl", "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl", "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:UpdateResponseHeadersPolicy", "cloudfront:DeleteResponseHeadersPolicy", "cloudfront:TagResource", "cloudfront:UntagResource", "cloudfront:CreateInvalidation",
    "cloudfront:CreateFunction", "cloudfront:UpdateFunction", "cloudfront:PublishFunction", "cloudfront:DeleteFunction"], Resource = "*" },
    { Effect = "Allow", Action = ["wafv2:CreateWebACL", "wafv2:UpdateWebACL", "wafv2:DeleteWebACL", "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL", "wafv2:TagResource", "wafv2:UntagResource"],
      Resource = ["arn:aws:wafv2:${local.region}:${local.account}:regional/webacl/${var.project}-*/*",
    "arn:aws:elasticloadbalancing:${local.region}:${local.account}:loadbalancer/app/${var.project}-*/*"] }
  ] })
}
resource "aws_iam_role_policy_attachment" "network" {
  for_each   = local.envs
  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.network.arn
}
resource "aws_iam_role_policy" "deploy" {
  for_each = local.envs
  role     = aws_iam_role.deploy[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.state.arn}/${each.key}/terraform.tfstate" },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.state.arn}/${each.key}/terraform.tfstate.tflock" },
    { Effect = "Allow", Action = ["kms:Encrypt", "kms:GenerateDataKey"], Resource = aws_kms_key.state.arn },
    { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.notifications.arn },
    { Effect = "Allow", Action = ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration", "s3:PutBucketLogging", "s3:PutBucketTagging",
      "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:ListBucketVersions"],
    Resource = ["arn:aws:s3:::${var.project}-${each.key}-${local.account}-*", "arn:aws:s3:::${var.project}-${each.key}-${local.account}-*/*"] },
    { Effect = "Allow", Action = ["dynamodb:CreateTable", "dynamodb:UpdateTable", "dynamodb:DeleteTable", "dynamodb:UpdateTimeToLive", "dynamodb:UpdateContinuousBackups", "dynamodb:TagResource", "dynamodb:UntagResource"],
    Resource = "arn:aws:dynamodb:${local.region}:${local.account}:table/${var.project}-${each.key}-chat" },
    { Effect = "Allow", Action = ["secretsmanager:CreateSecret", "secretsmanager:UpdateSecret", "secretsmanager:DeleteSecret", "secretsmanager:TagResource", "secretsmanager:UntagResource"],
    Resource = "arn:aws:secretsmanager:${local.region}:${local.account}:secret:${var.project}-${each.key}/anthropic-*" },
    { Effect = "Allow", Action = ["cognito-idp:CreateUserPool", "cognito-idp:UpdateUserPool", "cognito-idp:DeleteUserPool", "cognito-idp:CreateUserPoolClient", "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient", "cognito-idp:CreateUserPoolDomain", "cognito-idp:UpdateUserPoolDomain", "cognito-idp:DeleteUserPoolDomain", "cognito-idp:SetUserPoolMfaConfig", "cognito-idp:TagResource", "cognito-idp:UntagResource"],
    Resource = "arn:aws:cognito-idp:${local.region}:${local.account}:userpool/*" },
    { Effect = "Allow", Action = ["ecs:CreateCluster", "ecs:DeleteCluster", "ecs:UpdateCluster", "ecs:UpdateClusterSettings", "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService", "ecs:TagResource", "ecs:UntagResource"],
    Resource = ["arn:aws:ecs:${local.region}:${local.account}:cluster/${var.project}-${each.key}", "arn:aws:ecs:${local.region}:${local.account}:service/${var.project}-${each.key}/*"] },
    { Effect = "Allow", Action = ["ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition"], Resource = "*" },
    { Effect = "Allow", Action = ["ecs:TagResource", "ecs:UntagResource"], Resource = "arn:aws:ecs:${local.region}:${local.account}:task-definition/${var.project}-${each.key}:*" },
    { Effect = "Allow", Action = ["application-autoscaling:RegisterScalableTarget", "application-autoscaling:DeregisterScalableTarget", "application-autoscaling:PutScalingPolicy", "application-autoscaling:DeleteScalingPolicy", "application-autoscaling:TagResource", "application-autoscaling:UntagResource"], Resource = "*" },
    { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:PutMetricFilter", "logs:DeleteMetricFilter", "logs:TagResource", "logs:UntagResource"],
    Resource = ["arn:aws:logs:${local.region}:${local.account}:log-group:/ecs/${var.project}-${each.key}:*", "arn:aws:logs:${local.region}:${local.account}:log-group:/vpc/${var.project}-${each.key}:*"] },
    { Effect = "Allow", Action = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource"], Resource = "arn:aws:cloudwatch:${local.region}:${local.account}:alarm:${var.project}-${each.key}-*" },
    { Effect = "Allow", Action = ["cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards"], Resource = "arn:aws:cloudwatch::${local.account}:dashboard/${var.project}-${each.key}" },
    { Effect = "Allow", Action = ["sns:CreateTopic", "sns:DeleteTopic", "sns:SetTopicAttributes", "sns:TagResource", "sns:UntagResource", "sns:Publish"],
    Resource = "arn:aws:sns:${local.region}:${local.account}:${var.project}-${each.key}-notifications" },
    { Effect = "Allow", Action = ["iam:CreateRole"], Resource = "arn:aws:iam::${local.account}:role/${var.project}-runtime-${each.key}-*",
    Condition = { StringEquals = { "iam:PermissionsBoundary" = aws_iam_policy.runtime_boundary.arn } } },
    { Effect = "Allow", Action = ["iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole"],
    Resource = "arn:aws:iam::${local.account}:role/${var.project}-runtime-${each.key}-*" },
    { Effect = "Allow", Action = ["iam:PassRole"], Resource = "arn:aws:iam::${local.account}:role/${var.project}-runtime-${each.key}-*",
    Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "vpc-flow-logs.amazonaws.com"] } } },
    { Effect = "Allow", Action = ["iam:CreateServiceLinkedRole"], Resource = "arn:aws:iam::${local.account}:role/aws-service-role/*",
    Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com", "ecs.application-autoscaling.amazonaws.com"] } } }
  ] })
}
