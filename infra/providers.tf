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
}
