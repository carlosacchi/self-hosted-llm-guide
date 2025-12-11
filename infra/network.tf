resource "aws_vpc" "llm" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge({
    Name = "llm-gpu-vpc"
  }, local.lab_tags)
}

resource "aws_internet_gateway" "llm" {
  vpc_id = aws_vpc.llm.id

  tags = merge({
    Name = "llm-gpu-igw"
  }, local.lab_tags)
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.llm.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = merge({
    Name = "llm-gpu-public"
  }, local.lab_tags)
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.llm.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.llm.id
  }

  tags = merge({
    Name = "llm-gpu-public-rt"
  }, local.lab_tags)
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
