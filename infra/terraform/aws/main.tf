# ============================================================================
# AWS Infrastructure for S2S Attribution Server
# ============================================================================
#
# Architecture:
# - ECS Fargate: Serverless container deployment (auto-scaling)
# - Kinesis Firehose: Event streaming with auto Parquet conversion
# - S3: Parquet file storage (partitioned)
# - Glue Catalog: Metadata for Athena queries
# - ElastiCache Redis: Click ID storage with TTL
# - ALB: Application Load Balancer
#
# ============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

provider "aws" {
  region = var.region
}

# ============================================================================
# VPC and Networking
# ============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "s2s-vpc-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name        = "s2s-public-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "s2s-private-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "s2s-igw-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "s2s-public-rt-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ============================================================================
# S3 Bucket for Parquet Storage
# ============================================================================

resource "aws_s3_bucket" "parquet_storage" {
  bucket = "s2s-parquet-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "s2s-parquet-storage"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "parquet_lifecycle" {
  bucket = aws_s3_bucket.parquet_storage.id

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_versioning" "parquet_versioning" {
  bucket = aws_s3_bucket.parquet_storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_caller_identity" "current" {}

# ============================================================================
# Kinesis Firehose Delivery Streams (Auto Parquet Conversion)
# ============================================================================

resource "aws_kinesis_firehose_delivery_stream" "clicks" {
  name        = "s2s-clicks-${var.environment}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.parquet_storage.arn
    prefix     = "clicks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/tenant_id=!{partitionKeyFromQuery:tenant_id}/"
    error_output_prefix = "errors/clicks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = 128 # MB
    buffering_interval = 60  # seconds

    compression_format = "UNCOMPRESSED" # Parquet handles compression

    data_format_conversion_configuration {
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.s2s_catalog.name
        table_name    = aws_glue_catalog_table.clicks.name
        role_arn      = aws_iam_role.firehose_role.arn
      }
    }

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true

      processors {
        type = "MetadataExtraction"

        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }

        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{tenant_id:.tenant_id}"
        }
      }
    }
  }
}

resource "aws_kinesis_firehose_delivery_stream" "postbacks" {
  name        = "s2s-postbacks-${var.environment}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.parquet_storage.arn
    prefix     = "postbacks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/tenant_id=!{partitionKeyFromQuery:tenant_id}/"
    error_output_prefix = "errors/postbacks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = 128
    buffering_interval = 60

    compression_format = "UNCOMPRESSED"

    data_format_conversion_configuration {
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.s2s_catalog.name
        table_name    = aws_glue_catalog_table.postbacks.name
        role_arn      = aws_iam_role.firehose_role.arn
      }
    }

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true

      processors {
        type = "MetadataExtraction"

        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }

        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{tenant_id:.tenant_id}"
        }
      }
    }
  }
}

# ============================================================================
# IAM Role for Kinesis Firehose
# ============================================================================

resource "aws_iam_role" "firehose_role" {
  name = "s2s-firehose-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "firehose.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "firehose_s3_policy" {
  name = "s2s-firehose-s3-policy"
  role = aws_iam_role.firehose_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.parquet_storage.arn,
          "${aws_s3_bucket.parquet_storage.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetTableVersion",
          "glue:GetTableVersions"
        ]
        Resource = "*"
      }
    ]
  })
}

# ============================================================================
# Glue Catalog Database and Tables
# ============================================================================

resource "aws_glue_catalog_database" "s2s_catalog" {
  name = "s2s_attribution_${var.environment}"
}

resource "aws_glue_catalog_table" "clicks" {
  name          = "clicks"
  database_name = aws_glue_catalog_database.s2s_catalog.name

  table_type = "EXTERNAL_TABLE"

  partition_keys {
    name = "year"
    type = "string"
  }

  partition_keys {
    name = "month"
    type = "string"
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  partition_keys {
    name = "tenant_id"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.parquet_storage.bucket}/clicks/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "click_id"
      type = "string"
    }

    columns {
      name = "timestamp"
      type = "bigint"
    }

    columns {
      name = "ip_address"
      type = "string"
    }

    columns {
      name = "user_agent"
      type = "string"
    }

    columns {
      name = "target_url"
      type = "string"
    }

    columns {
      name = "utm_source"
      type = "string"
    }

    columns {
      name = "utm_medium"
      type = "string"
    }

    columns {
      name = "utm_campaign"
      type = "string"
    }

    columns {
      name = "device_type"
      type = "string"
    }

    columns {
      name = "country"
      type = "string"
    }
  }
}

resource "aws_glue_catalog_table" "postbacks" {
  name          = "postbacks"
  database_name = aws_glue_catalog_database.s2s_catalog.name

  table_type = "EXTERNAL_TABLE"

  partition_keys {
    name = "year"
    type = "string"
  }

  partition_keys {
    name = "month"
    type = "string"
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  partition_keys {
    name = "tenant_id"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.parquet_storage.bucket}/postbacks/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "click_id"
      type = "string"
    }

    columns {
      name = "timestamp"
      type = "bigint"
    }

    columns {
      name = "conversion_value"
      type = "double"
    }

    columns {
      name = "currency"
      type = "string"
    }

    columns {
      name = "latency_ms"
      type = "bigint"
    }

    columns {
      name = "matched"
      type = "boolean"
    }
  }
}

# ============================================================================
# ElastiCache Redis Cluster
# ============================================================================

resource "aws_elasticache_subnet_group" "redis" {
  name       = "s2s-redis-subnet-${var.environment}"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_security_group" "redis" {
  name        = "s2s-redis-sg-${var.environment}"
  description = "Security group for Redis cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "s2s-redis-${var.environment}"
  replication_group_description = "Redis cluster for S2S click ID storage"

  engine               = "redis"
  engine_version       = "7.0"
  node_type            = "cache.t3.medium"
  number_cache_clusters = 2
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  automatic_failover_enabled = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token_enabled         = true

  snapshot_retention_limit = 5
  snapshot_window          = "03:00-05:00"
  maintenance_window       = "sun:05:00-sun:07:00"
}

# ============================================================================
# Outputs
# ============================================================================

output "redis_endpoint" {
  description = "Redis cluster endpoint"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "s3_bucket" {
  description = "S3 bucket for Parquet storage"
  value       = aws_s3_bucket.parquet_storage.bucket
}

output "kinesis_clicks_stream" {
  description = "Kinesis Firehose clicks stream"
  value       = aws_kinesis_firehose_delivery_stream.clicks.name
}

output "kinesis_postbacks_stream" {
  description = "Kinesis Firehose postbacks stream"
  value       = aws_kinesis_firehose_delivery_stream.postbacks.name
}

output "glue_database" {
  description = "Glue catalog database"
  value       = aws_glue_catalog_database.s2s_catalog.name
}
