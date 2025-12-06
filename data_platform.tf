# --------------------------------------------------------------------------
# dataplatform.tf: Deploys the entire Airflow, Spark, Trino, Hive, Superset 
# platform
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

resource "docker_volume" "ollama_models" {
  name = "ollama_models"
  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true
  }
}

resource "docker_volume" "minio_data" {
  name = "minio_data"
  lifecycle {
    # Prevents 'terraform destroy' from deleting this network.
    prevent_destroy = true
  }
}

resource "docker_volume" "spark_events" {
  name = "spark_events"
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
    "AIRFLOW__CORE__SQL_ALCHEMY_CONN=postgresql+psycopg2://${var.POSTGRES_USER}:${var.POSTGRES_PASSWORD}@postgres:5432/${var.POSTGRES_DB}",
    "AIRFLOW__CORE__LOAD_EXAMPLES=false",
    "AIRFLOW__WEBSERVER__RBAC=true",
    "AIRFLOW_CONN_SPARK_DEFAULT=spark://spark-master:7077",
    "AIRFLOW_CONN_AWS_DEFAULT={'conn_type': 'aws', 'host': 'http://minio:9000', 'login': 'minioadmin', 'password': 'minioadminpassword', 'extra': {'aws_access_key_id': 'minioadmin', 'aws_secret_access_key': 'minioadminpassword', 'endpoint_url': 'http://minio:9000', 'region_name': 'us-east-1', 's3_verify': false}}",
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
    {
      volume_name    = docker_volume.spark_events.name
      container_path = "/opt/airflow/spark_events"
      read_only      = false
    },
    {
      host_path      = "${path.cwd}/spark-jobs"
      container_path = "/opt/bitnami/spark/jobs"
      read_only      = false
    },
  ]
}

# 2. Airflow Initializer
resource "docker_container" "airflow_init" {
  name  = "airflow_init"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Postgres at postgres:5432..."
    until PGPASSWORD=${var.POSTGRES_PASSWORD} psql -h postgres -U ${var.POSTGRES_USER} -d ${var.POSTGRES_DB} -c 'select 1' > /dev/null 2>&1; do
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

# 3. Airflow Webserver
resource "docker_container" "airflow_webserver" {
  name  = "airflow_webserver"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Postgres at postgres:5432..."
    until PGPASSWORD=${var.POSTGRES_PASSWORD} psql -h postgres -U ${var.POSTGRES_USER} -d ${var.POSTGRES_DB} -c 'select 1' > /dev/null 2>&1; do
      echo "Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Postgres is ready! Starting Airflow process..."
    exec webserver
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
  depends_on = [docker_container.airflow_init, docker_container.spark_master]
}

# 4. Airflow Scheduler
resource "docker_container" "airflow_scheduler" {
  name  = "airflow_scheduler"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Postgres at postgres:5432..."
    until PGPASSWORD=${var.POSTGRES_PASSWORD} psql -h postgres -U ${var.POSTGRES_USER} -d ${var.POSTGRES_DB} -c 'select 1' > /dev/null 2>&1; do
      echo "Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Postgres is ready! Starting Airflow process..."
    exec scheduler
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
  depends_on = [docker_container.airflow_init, docker_container.spark_master]
}

# 6. MinIO Service
resource "docker_container" "minio" {
  name  = "minio_storage"
  image = "minio/minio"
  ports {
    internal = 9000
    external = 9000
  }
  ports {
    internal = 9001
    external = 9001
  }
  env = [
    "MINIO_ROOT_USER=minioadmin",
    "MINIO_ROOT_PASSWORD=minioadminpassword",
  ]
  command = ["server", "/data", "--console-address", ":9001"]
  volumes {
    volume_name    = docker_volume.minio_data.name
    container_path = "/data"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}

# 7. Spark Master
resource "docker_container" "spark_master" {
  name  = "spark_master"
  image = var.SPARK_IMAGE_NAME
  ports {
    internal = 7077
    external = 7077
  }
  ports {
    internal = 8080
    external = 8081
  }
  command = ["/opt/spark/bin/spark-class", "org.apache.spark.deploy.master.Master"]
  env = [
    "SPARK_MASTER_WEBUI_PORT=8080",
    "SPARK_EVENT_LOG_ENABLED=true",
    "SPARK_EVENT_LOG_DIR=/opt/spark/events",
  ]
  volumes {
    host_path      = "${path.cwd}/spark-jobs"
    container_path = "/opt/spark/jobs"
  }
  volumes {
    volume_name    = docker_volume.spark_events.name
    container_path = "/opt/spark/events"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}

# 8. Spark Worker
resource "docker_container" "spark_worker" {
  name    = "spark_worker"
  image   = var.SPARK_IMAGE_NAME
  command = ["/opt/spark/bin/spark-class", "org.apache.spark.deploy.worker.Worker", "spark://spark-master:7077"]
  env = [
    "SPARK_MASTER_URL=spark://spark-master:7077",
    "SPARK_WORKER_CORES=2",
    "SPARK_WORKER_MEMORY=2g",
  ]
  volumes {
    volume_name    = docker_volume.spark_events.name
    container_path = "/opt/spark/events"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart    = "unless-stopped"
  depends_on = [docker_container.spark_master]
}

# 9. Trino Service
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
    host_path      = "${path.cwd}/trino_data"
    container_path = "/var/lib/trino"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart    = "unless-stopped"
  depends_on = [docker_container.minio]
}

# 10. Ollama Service
resource "docker_container" "ollama" {
  name  = "ollama_llm"
  image = "ollama/ollama:latest"
  ports {
    internal = 11434
    external = 11434
  }
  volumes {
    volume_name    = docker_volume.ollama_models.name
    container_path = "/root/.ollama"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
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

# Superset Initializer Service
resource "docker_container" "superset_init" {
  name    = "superset_init"
  image   = var.SUPERSET_IMAGE_NAME
  command = ["/bin/bash", "-c", "superset db upgrade && superset fab create-admin --username ${var.SUPERSET_ADMIN_USERNAME} --firstname Superset --lastname Admin --email ${var.SUPERSET_ADMIN_EMAIL} --password ${var.SUPERSET_ADMIN_PASSWORD} && superset init && echo 'Initialization complete. Pausing for 10 seconds...' && sleep 10"]
  env = [
    "SQLALCHEMY_DATABASE_URI=postgresql://${var.POSTGRES_USER}:${var.POSTGRES_PASSWORD}@postgres:5432/${var.POSTGRES_DB}",
    "SUPERSET_SECRET_KEY=${var.SUPERSET_SECRET_KEY}",
    "SUPERSET_ADMIN_PASSWORD=${var.SUPERSET_ADMIN_PASSWORD}",
    "SUPERSET_ADMIN_EMAIL=${var.SUPERSET_ADMIN_EMAIL}",
    "SUPERSET_ADMIN_USERNAME=${var.SUPERSET_ADMIN_USERNAME}",
  ]
  volumes {
    volume_name    = docker_volume.sqlite_data.name
    container_path = "/app"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  depends_on = [docker_container.hive_metastore, docker_container.postgres]
}

# Superset Webserver Service
resource "docker_container" "superset" {
  name  = "superset_app"
  image = var.SUPERSET_IMAGE_NAME
  ports {
    internal = 8088
    external = 8088
  }
  env = [
    "SUPERSET_LOAD_EXAMPLES=false",
    "SUPERSET_SECRET_KEY=${var.SUPERSET_SECRET_KEY}",
    "SQLALCHEMY_DATABASE_URI=postgresql://${var.POSTGRES_USER}:${var.POSTGRES_PASSWORD}@postgres:5432/${var.POSTGRES_DB}",
  ]
  volumes {
    volume_name    = docker_volume.sqlite_data.name
    container_path = "/app"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  depends_on = [docker_container.superset_init, docker_container.postgres]
}

# --- Outputs ---

output "data_platform_access" {
  description = "Connection URLs for the main services."
  value = {
    airflow_webserver = "http://localhost:8080"
    superset_ui       = "http://localhost:8088"
    spark_master_ui   = "http://localhost:8081"
    trino_ui          = "http://localhost:8082"
    minio_console     = "http://localhost:9001"
    ollama_api        = "http://localhost:11434"
  }
}

output "initial_credentials" {
  description = "Initial login credentials for Airflow and Superset."
  value = {
    airflow_user      = var._AIRFLOW_WWW_USER_USERNAME
    airflow_password  = var._AIRFLOW_WWW_USER_PASSWORD
    superset_user     = var.SUPERSET_ADMIN_USERNAME
    superset_password = var.SUPERSET_ADMIN_PASSWORD
  }
  sensitive = true
}
