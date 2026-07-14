variable "account_id" {
  description = "AWS account ID (12 digits). NO default on purpose: forces an explicit target and, with allowed_account_ids, guards against applying to the wrong account."
  type        = string
}

variable "region" {
  description = "Primary AWS region (one region everywhere to avoid S3/Athena/Glue drift)"
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "Local AWS CLI named profile (IAM Identity Center / SSO) Terraform authenticates with"
  type        = string
  default     = "weather-demo"
}

variable "name_prefix" {
  description = "Prefix for resource names (buckets append account_id for global uniqueness)"
  type        = string
  default     = "weather-demo"
}
