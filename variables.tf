# --------------------------------------------------------------------------
# variables.tf: Defines all input variables used by the configuration
# --------------------------------------------------------------------------

# PostgreSQL Credentials (Airflow/Superset Metadata DB)
variable "POSTGRES_METADATA_USER" {
  description = "PostgreSQL user for Airflow metadata DB."
  type        = string
  default     = "airflow"
}

variable "POSTGRES_METADATA_PASSWORD" {
  description = "PostgreSQL password for Airflow metadata DB."
  type        = string
  sensitive   = true
  default     = "airflow"
}

variable "POSTGRES_METADATA_DB" {
  description = "PostgreSQL database name for Airflow metadata DB."
  type        = string
  default     = "airflow"
}

variable "POSTGRES_METADATA_PORT" {
  description = "PostgreSQL exposed port."
  type        = number
  default     = 5432
}

variable "POSTGRES_METADATA_HOST" {
  description = "The name of the service that runs postgres."
  type        = string
  default     = "postgres"
}

# PostgreSQL Credentials for domain data.
variable "POSTGRES_DOMAIN_DATA_USER" {
  description = "PostgreSQL user for Airflow metadata DB."
  type        = string
  default     = "airflow"
}

variable "POSTGRES_DOMAIN_DATA_PASSWORD" {
  description = "PostgreSQL password for Airflow metadata DB."
  type        = string
  sensitive   = true
  default     = "airflow"
}

variable "POSTGRES_DOMAIN_DATA_DB" {
  description = "PostgreSQL database name for Airflow metadata DB."
  type        = string
  default     = "airflow"
}

variable "POSTGRES_DOMAIN_DATA_PORT" {
  description = "PostgreSQL exposed port."
  type        = number
  default     = 5432
}

variable "POSTGRES_DOMAIN_DATA_HOST" {
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
  # The newest version is incompatible with newspipe.
  # default = "apache/spark:4.1.0-scala2.13-java21-python3-r-ubuntu"
}

variable "SUPERSET_IMAGE_NAME" {
  description = "Docker image for Apache Superset."
  type        = string
  default     = "apache/superset:3.0.0"
}

# List of models to pull for Ollama (RAG creation).
variable "ollama_models_to_pull" {
  description = "A list of Ollama model names to be pulled by the init container."
  type        = list(string)
  default     = ["llama3", "nomic-embed-text", "gemma2", "phi3:mini", "qwen2:0.5b"]
}

variable "MINIO_ACCESS_KEY" {
  description = "Username for minio."
  type        = string
}

variable "MINIO_SECRET_KEY" {
  description = "Password for minio."
  type        = string
  sensitive   = true
}

variable "llm_api_keys" {
  type        = map(string)
  description = "A map of LLM API keys."
  sensitive   = true
}

variable "OPEN_WEBUI_SECRET_KEY" {
  type      = string
  sensitive = true
}

variable "LITELLM_MASTER_KEY" {
  type      = string
  sensitive = true
  # Must start with sk-
}

variable "LITELLM_ADMIN_USERNAME" {
  type    = string
  default = "admin"
}

variable "LITELLM_ADMIN_PASSWORD" {
  type      = string
  sensitive = true
}

variable "LITELLM_SALT_KEY" {
  type      = string
  sensitive = true
}

variable "NGROK_AUTHTOKEN" {
  type      = string
  sensitive = true
}
