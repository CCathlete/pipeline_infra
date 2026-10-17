# --------------------------------------------------------------------------
# variables.tf: Defines all input variables used by the configuration
# --------------------------------------------------------------------------

# PostgreSQL Credentials (Airflow Metadata DB)
variable "POSTGRES_USER" {
  description = "PostgreSQL user for Airflow metadata DB."
  type        = string
  default     = "airflow"
}

variable "POSTGRES_PASSWORD" {
  description = "PostgreSQL password for Airflow metadata DB."
  type        = string
  sensitive   = true
  default     = "airflow"
}

variable "POSTGRES_DB" {
  description = "PostgreSQL database name for Airflow metadata DB."
  type        = string
  default     = "airflow"
}

variable "POSTGRES_PORT" {
  description = "PostgreSQL exposed port."
  type        = number
  default     = 5432
}

variable "POSTGRES_HOST" {
  description = "The name of the service that runs postgres."
  type        = string
  default     = "postgres"
}


# Airflow Configuration and Credentials (Updated to match TFVARS structure)

variable "_AIRFLOW_WWW_USER_USERNAME" {
  description = "Airflow Webserver Admin username (matches dotenv source)."
  type        = string
  default     = "airflow"
}

variable "_AIRFLOW_WWW_USER_PASSWORD" {
  description = "Airflow Webserver Admin password (matches dotenv source)."
  type        = string
  sensitive   = true
  default     = "airflow"
}

variable "AIRFLOW_UID" {
  description = "UID used for Airflow containers to match host user."
  type        = number
  default     = 50001
}

variable "AIRFLOW_GID" {
  description = "GID used for Airflow containers."
  type        = number
  default     = 0
}


# Image Tags
variable "AIRFLOW_IMAGE_NAME" {
  description = "Docker image for Apache Airflow."
  type        = string
  default     = "apache/airflow:2.8.1"
}

variable "KAFKA_IMAGE_NAME" {
  description = "Docker image for Apache Kafka (KRaft mode, single node)."
  type        = string
  default     = "apache/kafka:3.7.0"
}


# RustFS Object Store (S3-compatible lakehouse for the bronze path)

variable "RUSTFS_ACCESS_KEY" {
  description = "Root access key for the RustFS object store."
  type        = string
  default     = "minioadmin"
}

variable "RUSTFS_SECRET_KEY" {
  description = "Root secret key for the RustFS object store."
  type        = string
  sensitive   = true
  default     = "minioadminpassword"
}

variable "RUSTFS_IMAGE_NAME" {
  description = "Docker image for RustFS, the S3-compatible lakehouse."
  type        = string
  default     = "rustfs/rustfs:latest"
}

variable "LAKEHOUSE_BUCKET" {
  description = "Bronze bucket ensured on first apply by the rustfs_init container."
  type        = string
  default     = "lakehouse"
}

variable "RUSTFS_S3_PORT" {
  description = "Host and container port for the RustFS S3 API."
  type        = number
  default     = 9000
}

variable "RUSTFS_CONSOLE_PORT" {
  description = "Host and container port for the RustFS console."
  type        = number
  default     = 9001
}
