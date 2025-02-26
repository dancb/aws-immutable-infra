# main.tf
provider "aws" {
  region = "us-east-1"
}

# Variables para etiquetas comunes
locals {
  terraform_tag = {
    "ManagedBy" = "Terraform"
    "Project"   = "ImmutableInfraPOC"
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.terraform_tag, { Name = "main-vpc" })
}

# Subnet Pública
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags                    = merge(local.terraform_tag, { Name = "public-subnet" })
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.terraform_tag, { Name = "main-igw" })
}

# Ruta para tráfico público
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.terraform_tag, { Name = "public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-sg"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.terraform_tag, { Name = "ec2-sg" })
}

# Instancia EC2
resource "aws_instance" "ec2" {
  ami                    = "ami-0e86e20dae9224db8" # Amazon Linux 2 en us-east-1
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  tags                   = merge(local.terraform_tag, { Name = "my-ec2-instance" })
}

# Bucket S3
resource "aws_s3_bucket" "immutable_infra" {
  bucket = "aws-inmutable-infra-poc-2025"
  acl    = "private"
  tags   = merge(local.terraform_tag, { Name = "ImmutableInfraPOC" })
}

# Bucket para estado de Terraform
resource "aws_s3_bucket" "terraform_state" {
  bucket = "my-terraform-state-bucket-2025"
  acl    = "private"
  tags   = merge(local.terraform_tag, { Name = "TerraformState" })
}

# Backend para estado de Terraform
terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket-2025"
    key            = "state/terraform.tfstate"
    region         = "us-east-1"
  }
}

# Bucket para logs de CloudTrail
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "my-cloudtrail-logs-2025"
  acl    = "private"
  tags   = merge(local.terraform_tag, { Name = "CloudTrailLogs" })
}

# CloudTrail
resource "aws_cloudtrail" "trail" {
  name                          = "tf-infra-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.bucket
  include_global_service_events = true
  is_multi_region_trail         = true
  tags                          = local.terraform_tag
}

# Regla de EventBridge para detectar cambios solo en recursos con tag ManagedBy=Terraform
resource "aws_cloudwatch_event_rule" "infra_changes" {
  name        = "detect-infra-changes"
  description = "Detecta cambios en recursos gestionados por Terraform"
  event_pattern = <<PATTERN
{
  "source": ["aws.ec2", "aws.s3"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["ec2.amazonaws.com", "s3.amazonaws.com"],
    "eventName": [
      "RunInstances", "TerminateInstances", "ModifyInstanceAttribute",
      "CreateSecurityGroup", "AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress",
      "PutBucketAcl", "PutBucketPolicy", "DeleteBucket", "CreateBucket"
    ],
    "requestParameters": {
      "tagSpecificationSet": {
        "items": [{
          "tags": [{
            "key": ["ManagedBy"],
            "value": ["Terraform"]
          }]
        }]
      }
    }
  }
}
PATTERN
}

# Rol IAM para Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "lambda_policy" {
  role = aws_iam_role.lambda_exec.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "execute-api:Invoke",
      "Resource": "*"
    }
  ]
}
EOF
}

# Función Lambda para disparar Jenkins
resource "aws_lambda_function" "trigger_jenkins" {
  filename      = "lambda.zip" # Crear con el código abajo
  function_name = "triggerJenkinsPipeline"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
}

# Vincular EventBridge a Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.infra_changes.name
  target_id = "TriggerJenkins"
  arn       = aws_lambda_function.trigger_jenkins.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger_jenkins.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.infra_changes.arn
}