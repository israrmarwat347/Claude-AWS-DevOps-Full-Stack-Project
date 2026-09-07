resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}
resource "aws_internet_gateway" "main" { vpc_id = aws_vpc.main.id }
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-public-${count.index}" }
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-private-${count.index}" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
}
resource "aws_nat_gateway" "main" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]
}
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[var.high_availability_nat ? count.index : 0].id
  }
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = "*",
    Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"],
  Resource = aws_dynamodb_table.chat.arn }] })
}
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "HTTPS only from CloudFront origin-facing addresses"
  vpc_id      = aws_vpc.main.id
}
resource "aws_vpc_security_group_ingress_rule" "cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "CloudFront HTTPS"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Only the ALB can reach backend tasks"
  vpc_id      = aws_vpc.main.id
}
resource "aws_vpc_security_group_egress_rule" "alb_tasks" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "tasks" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to Anthropic and AWS APIs via NAT; SGs cannot filter by DNS name"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
