# main.tf

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  default = "us-east-1"
}

variable "server_name" {
  default = "4mp3d's Server"
}

variable "world_name" {
  default = "Dedicated"
}

variable "password" {
  default = "Eriksson"
}

variable "server_port" {
  default = 2456
}

# VPC Setup
resource "aws_vpc" "valheim_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "valheim-vpc"
  }
}

resource "aws_internet_gateway" "valheim_igw" {
  vpc_id = aws_vpc.valheim_vpc.id

  tags = {
    Name = "valheim-igw"
  }
}

resource "aws_subnet" "valheim_subnet_1" {
  vpc_id                  = aws_vpc.valheim_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "valheim-subnet-1"
  }
}

resource "aws_subnet" "valheim_subnet_2" {
  vpc_id                  = aws_vpc.valheim_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "valheim-subnet-2"
  }
}

resource "aws_route_table" "valheim_rt" {
  vpc_id = aws_vpc.valheim_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.valheim_igw.id
  }

  tags = {
    Name = "valheim-rt"
  }
}

resource "aws_route_table_association" "valheim_rta_1" {
  subnet_id      = aws_subnet.valheim_subnet_1.id
  route_table_id = aws_route_table.valheim_rt.id
}

resource "aws_route_table_association" "valheim_rta_2" {
  subnet_id      = aws_subnet.valheim_subnet_2.id
  route_table_id = aws_route_table.valheim_rt.id
}

# Security Group
resource "aws_security_group" "valheim_sg" {
  name        = "valheim-sg"
  description = "Security group for Valheim server"
  vpc_id      = aws_vpc.valheim_vpc.id

  # Game port UDP
  ingress {
    from_port   = 2456
    to_port     = 2458
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Game port TCP (Steam)
  ingress {
    from_port   = 2456
    to_port     = 2458
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "valheim-sg"
  }
}

# EFS for persistent storage
resource "aws_efs_file_system" "valheim_data" {
  creation_token = "valheim-data"
  encrypted      = true

  tags = {
    Name = "valheim-data"
  }
}

resource "aws_efs_mount_target" "valheim_mt_1" {
  file_system_id  = aws_efs_file_system.valheim_data.id
  subnet_id       = aws_subnet.valheim_subnet_1.id
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_efs_mount_target" "valheim_mt_2" {
  file_system_id  = aws_efs_file_system.valheim_data.id
  subnet_id       = aws_subnet.valheim_subnet_2.id
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_security_group" "efs_sg" {
  name        = "efs-sg"
  description = "Security group for EFS"
  vpc_id      = aws_vpc.valheim_vpc.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.valheim_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-sg"
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "valheim_cluster" {
  name = "valheim-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# IAM Role for ECS Task
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "valheim-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM Role for ECS Task (for EFS access)
resource "aws_iam_role" "ecs_task_role" {
  name = "valheim-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "valheim_logs" {
  name              = "/ecs/valheim"
  retention_in_days = 7
}

# ECS Task Definition
resource "aws_ecs_task_definition" "valheim_task" {
  family                   = "valheim-server"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "2048" # 2 vCPU
  memory                   = "4096" # 4 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  volume {
    name = "valheim-data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.valheim_data.id
      transit_encryption = "ENABLED"
      authorization_config {
        iam = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    # Main Valheim server container
    {
      name      = "valheim-server"
      image     = "lloesche/valheim-server:latest"
      essential = true

      environment = [
        { name = "SERVER_NAME", value = var.server_name },
        { name = "WORLD_NAME", value = var.world_name },
        { name = "SERVER_PASS", value = var.password },
        { name = "SERVER_PUBLIC", value = "true" },
        { name = "UPDATE_INTERVAL", value = "10800" },
        { name = "BACKUPS", value = "3" },
        { name = "BACKUP_SHORT", value = "7200" },
        { name = "BACKUP_LONG", value = "43200" },
        { name = "STEAMCMD_ARGS", value = "" }
      ]

      mountPoints = [
        {
          sourceVolume  = "valheim-data"
          containerPath = "/config"
          readOnly      = false
        }
      ]

      portMappings = [
        { containerPort = 2456, protocol = "udp" },
        { containerPort = 2457, protocol = "udp" },
        { containerPort = 2458, protocol = "udp" },
        { containerPort = 2456, protocol = "tcp" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.valheim_logs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "valheim"
        }
      }
    },
    # Sidecar: Sync backups to S3 every 5 minutes
    {
      name      = "s3-sync"
      image     = "amazon/aws-cli:latest"
      essential = false

      command = [
        "sh", "-c",
        "while true; do aws s3 sync /config/backups s3://${aws_s3_bucket.valheim_backups.id}/backups/ --delete; sleep 300; done"
      ]

      mountPoints = [
        {
          sourceVolume  = "valheim-data"
          containerPath = "/config"
          readOnly      = true
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.valheim_logs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "s3-sync"
        }
      }
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "valheim_service" {
  name            = "valheim-server"
  cluster         = aws_ecs_cluster.valheim_cluster.id
  task_definition = aws_ecs_task_definition.valheim_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.valheim_subnet_1.id, aws_subnet.valheim_subnet_2.id]
    security_groups  = [aws_security_group.valheim_sg.id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}

# Outputs
output "ecs_cluster_name" {
  value = aws_ecs_cluster.valheim_cluster.name
}

output "efs_dns" {
  value = aws_efs_file_system.valheim_data.dns_name
}

output "public_ip" {
  description = "Public IP will be assigned to the task. Check ECS console or CloudWatch logs."
  value       = "Check AWS ECS Console for running task IP"
}

# S3 Bucket for backups
resource "aws_s3_bucket" "valheim_backups" {
  bucket = "valheim-backups-${data.aws_caller_identity.current.account_id}-${random_string.bucket_suffix.result}"
}

resource "aws_s3_bucket_versioning" "valheim_backups_versioning" {
  bucket = aws_s3_bucket.valheim_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "valheim_backups_lifecycle" {
  bucket = aws_s3_bucket.valheim_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = "" # Apply to all objects
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

data "aws_caller_identity" "current" {}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# IAM policy for S3 access
resource "aws_iam_role_policy" "ecs_task_s3_policy" {
  name = "valheim-s3-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.valheim_backups.arn,
          "${aws_s3_bucket.valheim_backups.arn}/*"
        ]
      }
    ]
  })
}