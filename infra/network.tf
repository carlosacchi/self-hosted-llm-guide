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

# Which of the requested instance types are offered where. GPU instances are not
# available in every AZ (eu-north-1a does not offer g5.xlarge, g7e is not
# everywhere g6e is), so this drives BOTH the subnet fan-out and the ASG's
# instance-type overrides -- there is no point offering the group a type the
# region has never heard of.
data "aws_ec2_instance_type_offerings" "gpu" {
  filter {
    name   = "instance-type"
    values = local.requested_instance_types
  }

  filter {
    name   = "location"
    values = data.aws_availability_zones.available.names
  }

  location_type = "availability-zone"
}

locals {
  # instance_types[i] is offered in locations[i] -- the two attributes are
  # parallel lists, not independent sets.
  az_offerings = [
    for i, t in data.aws_ec2_instance_type_offerings.gpu.instance_types : {
      instance_type = t
      az            = data.aws_ec2_instance_type_offerings.gpu.locations[i]
    }
  ]

  # Waterfall, filtered to what this region actually offers, order preserved.
  instance_type_waterfall = [
    for t in local.requested_instance_types : t
    if contains(data.aws_ec2_instance_type_offerings.gpu.instance_types, t)
  ]

  primary_instance_type = try(local.instance_type_waterfall[0], var.instance_type)

  # Every AZ that can serve at least one type in the waterfall. Sorted for
  # deterministic subnet CIDR assignment.
  candidate_azs = sort(distinct([for o in local.az_offerings : o.az]))

  # An explicit override narrows the hunt to one AZ, which is usually the wrong
  # thing to do now that the ASG can search -- kept for reproducing a known-good
  # placement.
  deploy_azs = var.availability_zone != "" ? [
    for az in local.candidate_azs : az if az == var.availability_zone
  ] : local.candidate_azs
}

# One /24 per candidate AZ. The ASG needs a subnet in every zone it is allowed
# to search; a single-subnet group can only ever fail in one place.
resource "aws_subnet" "public" {
  for_each = { for idx, az in local.deploy_azs : az => idx }

  vpc_id                  = aws_vpc.llm.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value)
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge({
    Name = "llm-gpu-public-${each.key}"
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
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
