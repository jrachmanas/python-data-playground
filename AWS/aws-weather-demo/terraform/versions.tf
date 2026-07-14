terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Safety rail: Terraform refuses to run if the credentials resolve to any
  # account other than this one. The SSO profile could in theory point elsewhere;
  # this makes "wrong-target" mistakes impossible rather than merely unlikely.
  allowed_account_ids = [var.account_id]
}
