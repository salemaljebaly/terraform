terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

resource "aws_vpc" "test_vpc" {
  tags = {
    Name = "firas_vpc"
    terraform = "true"
  }
  cidr_block = "10.0.0.0/16"
}