# --------------------------------------------------------------------------
# dataplatform.tf: Deploys the Airflow, Kafka, and S3 (LocalStack) platform
# (newspipe sister infra; Spark and Ollama removed, Kafka added)
# --------------------------------------------------------------------------

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

# --- Shared Network and Volumes ---

resource "docker_network" "my_shared_network" {
  name = "my_shared_network"

  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true

    # Ensures Terraform doesn't get confused if the name property changes.
    ignore_changes = [
      name
    ]
  }
}

resource "docker_volume" "postgres_data" {
  name = "postgres_data"
  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true
  }
}

resource "docker_volume" "localstack_data" {
  name = "localstack_data"
  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true
  }
}


resource "docker_volume" "trino_data" {
  name = "trino_data"
  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true
  }
}

resource "docker_volume" "sqlite_data" {
  name = "sqlite_data"
  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true
  }
}

resource "docker_volume" "kafka_data" {
  name = "kafka_data"
  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true
  }
}

# --- Service Containers ---

# 5. PostgreSQL
resource "docker_container" "postgres" {
  name  = var.POSTGRES_HOST
  image = "postgres:16-alpine"
  ports {
    internal = 5432
    external = var.POSTGRES_PORT
  }
  env = [
    "POSTGRES_USER=${var.POSTGRES_USER}",
    "POSTGRES_PASSWORD=${var.POSTGRES_PASSWORD}",
    "POSTGRES_DB=${var.POSTGRES_DB}",
    "PGDATA=/var/lib/postgresql/data/pgdata",
  ]
  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}

# Airflow Common Environment (used by multiple services)
locals {
  airflow_env = [
    "AIRFLOW_UID=${var.AIRFLOW_UID}",
    "AIRFLOW_GID=${var.AIRFLOW_GID}",
    "AIRFLOW_HOME=/opt/airflow",
    "AIRFLOW__CORE__EXECUTOR=LocalExecutor",
    "AIRFLOW__CORE__SQL_ALCHEMY_CONN=postgresql+psycopg2://${var.POSTGRES_USER}:${var.POSTGRES_PASSWORD}@${var.POSTGRES_HOST}:5432/${var.POSTGRES_DB}",
    "AIRFLOW__CORE__LOAD_EXAMPLES=false",
    "AIRFLOW__WEBSERVER__RBAC=true",
    "AIRFLOW_CONN_AWS_DEFAULT={'conn_type': 'aws', 'host': 'http://localstack:4566', 'login': 'minioadmin', 'password': 'minioadminpassword', 'extra': {'aws_access_key_id': 'minioadmin', 'aws_secret_access_key': 'minioadminpassword', 'endpoint_url': 'http://localstack:4566', 'region_name': 'us-east-1', 's3_verify': false}}",
    "POSTGRES_USER=${var.POSTGRES_USER}",
    "POSTGRES_PASSWORD=${var.POSTGRES_PASSWORD}",
    "POSTGRES_DB=${var.POSTGRES_DB}",
    "POSTGRES_HOST=${var.POSTGRES_HOST}",
  ]

  airflow_volumes = [
    {
      host_path      = "${path.cwd}/dags"
      container_path = "/opt/airflow/dags"
      read_only      = false
    },
    {
      host_path      = "${path.cwd}/logs"
      container_path = "/opt/airflow/logs"
      read_only      = false
    },
    {
      host_path      = "${path.cwd}/plugins"
      container_path = "/opt/airflow/plugins"
      read_only      = false
    },
  ]
}

# Airflow Initializer
resource "docker_container" "airflow_init" {
  name  = "airflow_init"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Postgres at ${var.POSTGRES_HOST}:5432..."
    until PGPASSWORD=${var.POSTGRES_PASSWORD} psql -h ${var.POSTGRES_HOST} -U ${var.POSTGRES_USER} -d ${var.POSTGRES_DB} -c 'select 1' > /dev/null 2>&1; do
      echo "Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Postgres is ready! Starting Airflow process..."
    airflow db init && airflow users create --username ${var._AIRFLOW_WWW_USER_USERNAME} --firstname Admin --lastname User --role Admin --email admin@example.com --password ${var._AIRFLOW_WWW_USER_PASSWORD}
  EOT
  ]
  env = local.airflow_env

  dynamic "volumes" {
    for_each = local.airflow_volumes
    content {
      host_path      = lookup(volumes.value, "host_path", null)
      volume_name    = lookup(volumes.value, "volume_name", null)
      container_path = volumes.value.container_path
      read_only      = volumes.value.read_only
    }
  }

  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  depends_on = [docker_container.postgres]
}

# Airflow Webserver
resource "docker_container" "airflow_webserver" {
  name  = "airflow_webserver"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Postgres at ${var.POSTGRES_HOST}:5432..."
    until PGPASSWORD=${var.POSTGRES_PASSWORD} psql -h ${var.POSTGRES_HOST} -U ${var.POSTGRES_USER} -d ${var.POSTGRES_DB} -c 'select 1' > /dev/null 2>&1; do
      echo "Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Postgres is ready! Starting Airflow process..."
    airflow webserver
  EOT
  ]
  ports {
    internal = 8080
    external = 8080
  }
  env = local.airflow_env

  dynamic "volumes" {
    for_each = local.airflow_volumes
    content {
      host_path      = lookup(volumes.value, "host_path", null)
      volume_name    = lookup(volumes.value, "volume_name", null)
      container_path = volumes.value.container_path
      read_only      = volumes.value.read_only
    }
  }

  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart    = "always"
  depends_on = [docker_container.airflow_init]
}

# Airflow Scheduler
resource "docker_container" "airflow_scheduler" {
  name  = "airflow_scheduler"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Postgres at ${var.POSTGRES_HOST}:5432..."
    until PGPASSWORD=${var.POSTGRES_PASSWORD} psql -h ${var.POSTGRES_HOST} -U ${var.POSTGRES_USER} -d ${var.POSTGRES_DB} -c 'select 1' > /dev/null 2>&1; do
      echo "Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Postgres is ready! Starting Airflow process..."
    airflow scheduler
  EOT
  ]
  env = local.airflow_env

  dynamic "volumes" {
    for_each = local.airflow_volumes
    content {
      host_path      = lookup(volumes.value, "host_path", null)
      volume_name    = lookup(volumes.value, "volume_name", null)
      container_path = volumes.value.container_path
      read_only      = volumes.value.read_only
    }
  }

  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart    = "always"
  depends_on = [docker_container.airflow_init]
}

# LocalStack Service (S3 gateway for the lakehouse bronze path)
resource "docker_container" "localstack" {
  name  = "localstack"
  image = "localstack/localstack:3.8"
  ports {
    internal = 4566
    external = 4566
  }
  env = [
    "SERVICES=s3",
  ]
  volumes {
    volume_name    = docker_volume.localstack_data.name
    container_path = "/var/lib/localstack"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}

# Trino Service
resource "docker_container" "trino" {
  name  = "trino_query_engine"
  image = "trinodb/trino:latest"
  ports {
    internal = 8080
    external = 8082
  }
  user       = "1000:1000"
  entrypoint = ["/usr/lib/trino/bin/run-trino"]
  volumes {
    host_path      = "${path.cwd}/trino/etc"
    container_path = "/etc/trino"
  }
  volumes {
    volume_name    = docker_volume.trino_data.name
    container_path = "/var/lib/trino"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart    = "unless-stopped"
  depends_on = [docker_container.localstack]
}


# SQLite Service
resource "docker_container" "sqlite" {
  name    = "sqlite_metastore_db"
  image   = "busybox:latest"
  command = ["tail", "-f", "/dev/null"]
  volumes {
    volume_name    = docker_volume.sqlite_data.name
    container_path = "/data"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
}


# Hive Metastore Service
resource "docker_container" "hive_metastore" {
  name  = "hive_metastore"
  image = "apache/hive:3.1.3"
  ports {
    internal = 9083
    external = 9083
  }
  env = [
    "HADOOP_HEAPSIZE=512",
    "SERVICE_NAME=metastore",
    "METASTORE_DB_HOSTNAME=sqlite",
    "METASTORE_DB_TYPE=sqlite",
    "METASTORE_DB_NAME=/data/metastore.db",
  ]
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  depends_on = [docker_container.sqlite]
}


# Kafka Service (KRaft, single node; newspipe raw_rss topic)
resource "docker_container" "kafka" {
  name  = "kafka"
  image = var.KAFKA_IMAGE_NAME
  ports {
    internal = 9092
    external = 9092
  }
  env = [
    "KAFKA_NODE_ID=1",
    "KAFKA_PROCESS_ROLES=broker,controller",
    "KAFKA_LISTENERS=PLAINTEXT://:29092,CONTROLLER://:29093,PLAINTEXT_HOST://:9092",
    "KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:29092,PLAINTEXT_HOST://localhost:9092",
    "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT",
    "KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka:29093",
    "KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER",
    "KAFKA_HEAP_OPTS=-Xmx512M -Xms512M",
    "KAFKA_LOG_DIRS=/var/lib/kafka/data",
    "KAFKA_AUTO_CREATE_TOPICS_ENABLE=true",
    "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1",
    "KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS=1",
    "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1",
    "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1",
    "KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0",
    "CLUSTER_ID=MkU3OEVBNTcwNTJENDM2Qk",
  ]
  volumes {
    volume_name    = docker_volume.kafka_data.name
    container_path = "/var/lib/kafka/data"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}

# --- Outputs ---

output "data_platform_access" {
  description = "Connection URLs for the main services."
  value = {
    airflow_webserver = "http://localhost:8080"
    trino_ui          = "http://localhost:8082"
    localstack_s3     = "http://localhost:4566"
    kafka_bootstrap   = "localhost:9092"
  }
}

output "initial_credentials" {
  description = "Initial login credentials for Airflow."
  value = {
    airflow_user     = var._AIRFLOW_WWW_USER_USERNAME
    airflow_password = var._AIRFLOW_WWW_USER_PASSWORD
  }
  sensitive = true
}
