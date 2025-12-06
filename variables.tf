# --------------------------------------------------------------------------
# variables.tf: Defines all input variables used by the configuration
# --------------------------------------------------------------------------

# PostgreSQL Credentials (Airflow/Superset Metadata DB)
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


# Superset Credentials
variable "SUPERSET_ADMIN_USERNAME" {
  description = "Superset Admin username."
  type        = string
  default     = "admin"
}

variable "SUPERSET_ADMIN_PASSWORD" {
  description = "Superset Admin password."
  type        = string
  sensitive   = true
  default     = "password"
}

variable "SUPERSET_ADMIN_EMAIL" {
  description = "Superset Admin email."
  type        = string
  default     = "admin@superset.com"
}

variable "SUPERSET_SECRET_KEY" {
  description = "Superset secret key for session signing."
  type        = string
  sensitive   = true
  default     = "this_is_a_default_key_change_me"
}


# Image Tags
variable "AIRFLOW_IMAGE_NAME" {
  description = "Docker image for Apache Airflow."
  type        = string
  default     = "apache/airflow:2.8.1"
}

variable "SPARK_IMAGE_NAME" {
  description = "Docker image for Apache Spark."
  type        = string
  default     = "apache/spark:3.5.1"
}

variable "SUPERSET_IMAGE_NAME" {
  description = "Docker image for Apache Superset."
  type        = string
  default     = "apache/superset:3.0.0"
}
