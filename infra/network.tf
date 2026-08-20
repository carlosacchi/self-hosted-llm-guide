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

data "aws_availability_zones" "available" {
  state = "available"
}

# Availability zones in the active region that actually offer the requested
# instance type (g5 GPU instances are not available in every AZ, e.g.
# eu-north-1a does not offer g5.xlarge). We intersect this with the region's
# available AZs and pick the first valid one.
data "aws_ec2_instance_type_offerings" "gpu" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  filter {
    name   = "location"
    values = data.aws_availability_zones.available.names
  }

  location_type = "availability-zone"
}

locals {
  # AZs (sorted for determinism) that support the instance type.
  supported_azs = sort(data.aws_ec2_instance_type_offerings.gpu.locations)

  # Explicit override wins; otherwise use the first AZ that supports the type.
  # try() keeps an unsupported region from failing here with a bare "Invalid
  # index"; the subnet precondition below explains what actually went wrong.
  selected_az = var.availability_zone != "" ? var.availability_zone : try(local.supported_azs[0], "")
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.llm.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.selected_az
  map_public_ip_on_launch = true

  lifecycle {
    precondition {
      condition     = local.selected_az != ""
      error_message = "Instance type ${var.instance_type} is not offered in any availability zone of ${var.aws_region}. Pick another region: g6e.12xlarge, for example, exists in eu-central-1 and eu-north-1 but not in eu-west-1."
    }
  }

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
