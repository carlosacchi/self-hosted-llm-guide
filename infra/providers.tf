terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.58"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  # Fail fast on InsufficientInstanceCapacity. The AWS provider treats that as a
  # retriable error and otherwise retries up to its default of 25 times with
  # exponential backoff, which can hang `apply` for ~50 minutes before erroring.
  # A small cap surfaces a capacity shortage in a minute or two so you can
  # re-run against a different AZ/region instead of waiting.
  max_retries = var.aws_max_retries
}
