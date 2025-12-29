# --------------------------------------------------------------------------
# dataplatform.tf: Deploys the entire Airflow, Spark, Trino, Hive, Superset 
# platform with dedicated Metadata and Data PostgreSQL databases.
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
    # prevent_destroy = true
    prevent_destroy = false
    ignore_changes = [
      name
    ]
  }
}

resource "docker_volume" "postgres_data_metadata" {
  name = "postgres_data_metadata"
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "postgres_data_domain" {
  name = "postgres_data_domain"
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "ollama_models" {
  name = "ollama_models"
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "minio_data" {
  name = "minio_data"
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "spark_events" {
  name = "spark_events"
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "sqlite_data" {
  name = "sqlite_data"
  lifecycle {
    prevent_destroy = true
  }
}

# --- Kafka Storage ---
resource "docker_volume" "kafka_data" {
  name = "kafka_data"
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "open_webui_data" {
  name = "open_webui_data"
  lifecycle {
    # Keeps your prompts and history safe even if you terraform destroy
    prevent_destroy = true
  }
}

# --- Local Variables ---
locals {
  # New Service Hostnames for internal Docker network
  postgres_metadata_host = "postgres_metadata_db"
  postgres_data_host     = "postgres_data_db"

  # Airflow Common Environment (now points to the Metadata DB using new variables)
  airflow_env = [
    "AIRFLOW_UID=${var.AIRFLOW_UID}",
    "AIRFLOW_GID=${var.AIRFLOW_GID}",
    "AIRFLOW_HOME=/opt/airflow",
    "AIRFLOW__CORE__EXECUTOR=LocalExecutor",
    # CRITICAL: Airflow connects to the dedicated Metadata DB
    "AIRFLOW__CORE__SQL_ALCHEMY_CONN=postgresql+psycopg2://${var.POSTGRES_METADATA_USER}:${var.POSTGRES_METADATA_PASSWORD}@${local.postgres_metadata_host}:5432/${var.POSTGRES_METADATA_DB}",
    "AIRFLOW__CORE__LOAD_EXAMPLES=false",
    "AIRFLOW__WEBSERVER__RBAC=true",
    "AIRFLOW_CONN_SPARK_DEFAULT=spark://spark-master:7077",
    "AIRFLOW_CONN_AWS_DEFAULT={'conn_type': 'aws', 'host': 'http://minio-storage:9000', 'login': '${var.MINIO_ACCESS_KEY}', 'password': '${var.MINIO_SECRET_KEY}', 'extra': {'aws_access_key_id': '${var.MINIO_ACCESS_KEY}', 'aws_secret_access_key': '${var.MINIO_SECRET_KEY}', 'endpoint_url': 'http://minio-storage:9000', 'region_name': 'us-east-1', 's3_verify': false}}",

    # Exposing Metadata DB connection details
    "POSTGRES_USER=${var.POSTGRES_METADATA_USER}",
    "POSTGRES_PASSWORD=${var.POSTGRES_METADATA_PASSWORD}",
    "POSTGRES_DB=${var.POSTGRES_METADATA_DB}",
    "POSTGRES_HOST=${local.postgres_metadata_host}",

    # Exposing Data DB connection details for use inside DAGs
    "POSTGRES_DOMAIN_DATA_HOST=${local.postgres_data_host}",
    "POSTGRES_DOMAIN_DATA_PORT=5432", # Internal port
    "POSTGRES_DOMAIN_DATA_USER=${var.POSTGRES_DOMAIN_DATA_USER}",
    "POSTGRES_DOMAIN_DATA_PASSWORD=${var.POSTGRES_DOMAIN_DATA_PASSWORD}",
    "POSTGRES_DOMAIN_DATA_DB=${var.POSTGRES_DOMAIN_DATA_DB}",
  ]

  hive_site_xml = templatefile(
    "${path.cwd}/hive/hive-site.xml.tmpl",
    {
      # CRITICAL: Hive Metastore connects to the dedicated Metadata DB
      postgres_host     = local.postgres_metadata_host
      postgres_port     = 5432
      postgres_db       = var.POSTGRES_METADATA_DB
      postgres_user     = var.POSTGRES_METADATA_USER
      postgres_password = var.POSTGRES_METADATA_PASSWORD
    }
  )
  core_site_xml = templatefile(
    "${path.cwd}/hive/core-site.xml.tmpl",
    {
      minio_access_key = var.MINIO_ACCESS_KEY
      minio_secret_key = var.MINIO_SECRET_KEY
    }
  )

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

  pull_commands_string = join(" && ", [for model in var.ollama_models_to_pull : format("ollama pull %s", model)])
}

# --- Local Files ---
resource "local_file" "hive_site_rendered" {
  content  = local.hive_site_xml
  filename = "${path.cwd}/generated/hive-site.xml"
}
resource "local_file" "core_site_rendered" {
  content  = local.core_site_xml
  filename = "${path.cwd}/generated/core-site.xml"
}

# --- Service Containers ---

# 5. PostgreSQL Metadata DB (For Airflow/Superset/Hive Schemas)
resource "docker_container" "postgres_metadata" {
  name  = local.postgres_metadata_host
  image = "postgres:16-alpine"
  ports {
    internal = 5432
    external = var.POSTGRES_METADATA_PORT
  }
  env = [
    "POSTGRES_USER=${var.POSTGRES_METADATA_USER}",
    "POSTGRES_PASSWORD=${var.POSTGRES_METADATA_PASSWORD}",
    "POSTGRES_DB=${var.POSTGRES_METADATA_DB}",
    "PGDATA=/var/lib/postgresql/data/pgdata",
  ]
  volumes {
    volume_name    = docker_volume.postgres_data_metadata.name
    container_path = "/var/lib/postgresql/data"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}

# 6. PostgreSQL Data DB (For Domain-Specific Production Data)
resource "docker_container" "postgres_data" {
  name = local.postgres_data_host
  # image = "postgres:16-alpine"
  image = "pgvector/pgvector:pg16"
  ports {
    internal = 5432
    external = var.POSTGRES_DOMAIN_DATA_PORT # Exposed on new port
  }
  env = [
    "POSTGRES_USER=${var.POSTGRES_DOMAIN_DATA_USER}",
    "POSTGRES_PASSWORD=${var.POSTGRES_DOMAIN_DATA_PASSWORD}",
    "POSTGRES_DB=${var.POSTGRES_DOMAIN_DATA_DB}",
    "PGDATA=/var/lib/postgresql/data/pgdata",
  ]
  volumes {
    volume_name    = docker_volume.postgres_data_domain.name
    container_path = "/var/lib/postgresql/data"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}


# Airflow Initializer
resource "docker_container" "airflow_init" {
  name  = "airflow_init"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Metadata Postgres at ${local.postgres_metadata_host}:5432..."
    until PGPASSWORD=${var.POSTGRES_METADATA_PASSWORD} psql -h ${local.postgres_metadata_host} -U ${var.POSTGRES_METADATA_USER} -d ${var.POSTGRES_METADATA_DB} -c 'select 1';
    do
      echo "Metadata Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Metadata Postgres is ready! Starting Airflow process..."
    pip install mypy_boto3_s3
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
  depends_on = [docker_container.postgres_metadata]
}

# Airflow Webserver
resource "docker_container" "airflow_webserver" {
  name  = "airflow_webserver"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Metadata Postgres at ${local.postgres_metadata_host}:5432..."
    until PGPASSWORD=${var.POSTGRES_METADATA_PASSWORD} psql -h ${local.postgres_metadata_host} -U ${var.POSTGRES_METADATA_USER} -d ${var.POSTGRES_METADATA_DB} -c 'select 1' > /dev/null 2>&1;
    do
      echo "Metadata Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Metadata Postgres is ready! Starting Airflow process..."
    pip install mypy_boto3_s3
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
  depends_on = [docker_container.airflow_init, docker_container.spark-master, docker_container.minio, docker_container.postgres_metadata]
}

# Airflow Scheduler
resource "docker_container" "airflow_scheduler" {
  name  = "airflow_scheduler"
  image = var.AIRFLOW_IMAGE_NAME
  user  = "${var.AIRFLOW_UID}:0"
  command = ["bash", "-c", <<-EOT
    echo "Waiting for Metadata Postgres at ${local.postgres_metadata_host}:5432..."
    until PGPASSWORD=${var.POSTGRES_METADATA_PASSWORD} psql -h ${local.postgres_metadata_host} -U ${var.POSTGRES_METADATA_USER} -d ${var.POSTGRES_METADATA_DB} -c 'select 1' > /dev/null 2>&1;
    do
      echo "Metadata Postgres is unavailable - sleeping"
      sleep 1
    done
    echo "Metadata Postgres is ready! Starting Airflow process..."
    pip install mypy_boto3_s3
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
  depends_on = [docker_container.airflow_init, docker_container.spark-master, docker_container.minio, docker_container.postgres_metadata]
}

# MinIO Service
resource "docker_container" "minio" {
  name  = "minio-storage"
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
    "MINIO_ROOT_USER=${var.MINIO_ACCESS_KEY}",
    "MINIO_ROOT_PASSWORD=${var.MINIO_SECRET_KEY}",
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

# Spark Master
resource "docker_container" "spark-master" {
  name  = "spark-master"
  image = var.SPARK_IMAGE_NAME
  ports {
    internal = 7077
    external = 7077
  }
  ports {
    internal = 8080
    external = 8181
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

  # Jars for S3 support.
  volumes {
    host_path      = "${path.cwd}/hive/hadoop-aws-3.3.4.jar"
    container_path = "/opt/spark/jars/hadoop-aws-3.3.4.jar"
  }

  volumes {
    host_path      = "${path.cwd}/hive/hadoop-client-3.3.4.jar"
    container_path = "/opt/spark/jars/hadoop-client-3.3.4.jar"
  }

  volumes {
    host_path      = "${path.cwd}/hive/hadoop-common-3.3.4.jar"
    container_path = "/opt/spark/jars/hadoop-common-3.3.4.jar"
  }

  volumes {
    host_path      = "${path.cwd}/hive/aws-java-sdk-bundle-1.12.262.jar"
    container_path = "/opt/spark/jars/aws-java-sdk-bundle-1.12.262.jar"
  }

  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart = "unless-stopped"
}

# Spark Worker
resource "docker_container" "spark-worker" {
  name    = "spark-worker"
  image   = var.SPARK_IMAGE_NAME
  command = ["/opt/spark/bin/spark-class", "org.apache.spark.deploy.worker.Worker", "spark://spark-master:7077"]
  env = [
    "SPARK_MASTER_URL=spark://spark-master:7077",
    "SPARK_WORKER_CORES=4",
    "SPARK_WORKER_MEMORY=6g",
    "SPARK_EXECUTOR_CORES=1",
    "SPARK_EXECUTOR_MEMORY=2g",
    "SPARK_EXECUTOR_INSTANCES=3",
    "SPARK_CLASSPATH=/opt/spark/jars/hadoop-common-3.3.4.jar:/opt/spark/jars/hadoop-aws-3.3.4.jar:/opt/spark/jars/aws-java-sdk-bundle-1.12.262.jar",
  ]


  volumes {
    volume_name    = docker_volume.spark_events.name
    container_path = "/opt/spark/events"
  }

  # Jars for S3 support.
  volumes {
    host_path      = "${path.cwd}/hive/hadoop-aws-3.3.4.jar"
    container_path = "/opt/spark/jars/hadoop-aws-3.3.4.jar"
  }

  volumes {
    host_path      = "${path.cwd}/hive/hadoop-client-3.3.4.jar"
    container_path = "/opt/spark/jars/hadoop-client-3.3.4.jar"
  }

  volumes {
    host_path      = "${path.cwd}/hive/hadoop-common-3.3.4.jar"
    container_path = "/opt/spark/jars/hadoop-common-3.3.4.jar"
  }

  volumes {
    host_path      = "${path.cwd}/hive/aws-java-sdk-bundle-1.12.262.jar"
    container_path = "/opt/spark/jars/aws-java-sdk-bundle-1.12.262.jar"
  }

  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  restart    = "unless-stopped"
  depends_on = [docker_container.spark-master]
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
    host_path      = "${path.cwd}/trino_data"
    container_path = "/var/lib/trino"
  }
  networks_advanced {
    name    = docker_network.my_shared_network.name
    aliases = ["trino"]
  }
  restart    = "unless-stopped"
  depends_on = [docker_container.minio, docker_container.hive-metastore]
}

# # Ollama Initializer
# resource "docker_container" "ollama_init" {
#   name  = "ollama_init"
#   image = "ollama/ollama:latest"

#   entrypoint = ["/bin/sh"]
#   command = [
#     "-c",
#     <<-EOT
#       # Start server in background
#       ollama serve &
#       PID=$!

#       # Wait for the server to fully start
#       sleep 5

#       # Run all pull commands (ensuring success)
#       ${local.pull_commands_string}

#       # Kill the background server process
#       kill $PID
#     EOT
#   ]

#   volumes {
#     volume_name    = docker_volume.ollama_models.name
#     container_path = "/root/.ollama"
#   }
#   networks_advanced {
#     name = docker_network.my_shared_network.name
#   }
#   depends_on = [docker_volume.ollama_models]
#   must_run   = false

#   # Extracting logs if container is terminated.
#   provisioner "local-exec" {
#     when    = destroy
#     command = "docker logs ${self.name} || true"
#   }
# }

# # Ollama Service
# resource "docker_container" "ollama" {
#   name  = "ollama_llm"
#   image = "ollama/ollama:latest"
#   ports {
#     internal = 11434
#     external = 11434
#   }
#   volumes {
#     volume_name    = docker_volume.ollama_models.name
#     container_path = "/root/.ollama"
#   }
#   networks_advanced {
#     name = docker_network.my_shared_network.name
#   }
#   depends_on = [docker_container.ollama_init]
#   restart    = "unless-stopped"
# }

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

# Hive schema initialization (Runs before the main Metastore service)
resource "null_resource" "hive_init_schema" {
  depends_on = [
    docker_container.postgres_metadata,
    local_file.hive_site_rendered,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      echo "Waiting for Metadata Postgres at ${local.postgres_metadata_host}:5432..."
      
      # Loop until psql command succeeds.
      until docker exec ${local.postgres_metadata_host} psql -U ${var.POSTGRES_METADATA_USER} -d ${var.POSTGRES_METADATA_DB} -c "SELECT 'Running this from within postgres';" ; do
        echo "Postgres is not accepting connections yet... sleeping"
        sleep 2
      done
      
      echo "Postgres is ready. Starting Hive schematool initialization..."

      # Run the temporary container to execute schematool
      docker run --rm \
          --network ${docker_network.my_shared_network.name} \
          --entrypoint /bin/bash \
          -v ${path.cwd}/generated/hive-site.xml:/opt/hive/conf/hive-site.xml \
          -v ${path.cwd}/hive/postgresql-42.7.3.jar:/opt/hive/lib/postgresql-42.7.3.jar \
          -v ${path.cwd}/hive/aws-java-sdk-bundle-1.11.1026.jar:/opt/hive/lib/aws-java-sdk-bundle-1.11.1026.jar \
          -v ${path.cwd}/hive/hadoop-aws-3.3.3.jar:/opt/hive/lib/hadoop-aws-3.3.3.jar \
          -v ${path.cwd}/generated/core-site.xml:/opt/hive/conf/core-site.xml \
          -e HIVE_CONF_DIR=/opt/hive/conf \
          -e HADOOP_CONF_DIR=/opt/hive/conf \
          -e HADOOP_CLIENT_OPTS='-Xmx2G' \
          apache/hive:4.1.0 \
          -c "/opt/hive/bin/schematool -dbType postgres -initSchema"
          
      # Check if the schematool command succeeded before marking the resource complete
      if [ $? -ne 0 ]; then
        echo "ERROR: Hive schematool failed to initialize schema!"
        exit 1
      fi
      
      echo "Hive schema initialization successful."
    EOT
  }
}


# Hive Metastore Service
resource "docker_container" "hive-metastore" {
  name    = "hive-metastore"
  image   = "apache/hive:4.1.0"
  restart = "unless-stopped"

  ports {
    internal = 9083
    external = 9083
  }
  entrypoint = ["/opt/hive/bin/hive"]
  command    = ["--service", "metastore"]

  # Mount the rendered XML and Postgres driver
  volumes {
    host_path      = "${path.cwd}/generated/hive-site.xml"
    container_path = "/opt/hive/conf/hive-site.xml"
  }
  volumes {
    host_path      = "${path.cwd}/generated/core-site.xml"
    container_path = "/opt/hive/conf/core-site.xml"
  }
  volumes {
    host_path      = "${path.cwd}/hive/postgresql-42.7.3.jar"
    container_path = "/opt/hive/lib/postgresql-42.7.3.jar"
  }
  volumes {
    host_path      = "${path.cwd}/hive/aws-java-sdk-bundle-1.11.1026.jar"
    container_path = "/opt/hive/lib/aws-java-sdk-bundle-1.11.1026.jar"
  }
  volumes {
    host_path      = "${path.cwd}/hive/hadoop-aws-3.3.3.jar"
    container_path = "/opt/hive/lib/hadoop-aws-3.3.3.jar"
  }
  volumes {
    host_path      = "${path.cwd}/hive/aws-java-sdk-bundle-1.11.1026.jar"
    container_path = "/opt/hadoop/share/hadoop/common/lib/aws-java-sdk-bundle-1.11.1026.jar"
  }
  volumes {
    host_path      = "${path.cwd}/hive/hadoop-aws-3.3.3.jar"
    container_path = "/opt/hadoop/share/hadoop/common/lib/hadoop-aws-3.3.3.jar"
  }
  volumes {
    host_path      = "${path.cwd}/hive/core-default.xml"
    container_path = "/opt/hive/conf/core-default.xml"
  }

  env = [
    "SERVICE_NAME=metastore",
    "HIVE_EXECUTION_ENGINE=mr",
    "HADOOP_CONF_DIR=/opt/hive/conf",
    "HIVE_CONF_DIR=/opt/hive/conf",
  ]

  networks_advanced {
    name    = docker_network.my_shared_network.name
    aliases = ["hive-metastore"]
  }

  depends_on = [null_resource.hive_init_schema]
}

# Superset Initializer Service
resource "docker_container" "superset_init" {
  name  = "superset_init"
  image = var.SUPERSET_IMAGE_NAME

  command = [
    "/bin/bash",
    "-c",
    <<-EOT
      pip install trino sqlalchemy-trino
      superset db upgrade 
      superset fab create-admin --username ${var.SUPERSET_ADMIN_USERNAME} --firstname Superset --lastname Admin --email ${var.SUPERSET_ADMIN_EMAIL} --password ${var.SUPERSET_ADMIN_PASSWORD}
      superset init
      echo 'Initialization complete. Pausing for 10 seconds...'
      sleep 10
    EOT
  ]

  env = [
    # CRITICAL: Superset connects to the Metadata DB
    "SQLALCHEMY_DATABASE_URI=postgresql://${var.POSTGRES_METADATA_USER}:${var.POSTGRES_METADATA_PASSWORD}@${local.postgres_metadata_host}:5432/${var.POSTGRES_METADATA_DB}",
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
  depends_on = [docker_container.hive-metastore, docker_container.postgres_metadata]

  provisioner "local-exec" {
    when    = destroy
    command = "docker logs ${self.name} || true"
  }
}

# Superset Webserver Service
resource "docker_container" "superset" {
  name    = "superset_app"
  image   = var.SUPERSET_IMAGE_NAME
  restart = "unless-stopped"

  ports {
    internal = 8088
    external = 8088
  }
  env = [
    "SUPERSET_LOAD_EXAMPLES=false",
    "SUPERSET_SECRET_KEY=${var.SUPERSET_SECRET_KEY}",
    # CRITICAL: Superset connects to the Metadata DB
    "SQLALCHEMY_DATABASE_URI=postgresql://${var.POSTGRES_METADATA_USER}:${var.POSTGRES_METADATA_PASSWORD}@${local.postgres_metadata_host}:5432/${var.POSTGRES_METADATA_DB}",
  ]
  volumes {
    volume_name    = docker_volume.sqlite_data.name
    container_path = "/app"
  }
  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  depends_on = [docker_container.superset_init, docker_container.postgres_metadata]
}

# --- Kafka Broker (KRaft Mode) ---
resource "docker_container" "kafka" {
  name  = "kafka_broker"
  image = "confluentinc/cp-kafka:7.5.0"

  # Connecting from the inner network (other containers).
  ports {
    internal = 9092
    external = 9092
  }

  # Connecting from host.
  ports {
    internal = 29092
    external = 29092
  }

  env = [
    "KAFKA_NODE_ID=1",
    "KAFKA_PROCESS_ROLES=broker,controller",
    # Listeners: 9092 for internal Docker, 29092 for your laptop, 9093 for Controller
    "KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,PLAINTEXT_HOST://0.0.0.0:29092,CONTROLLER://0.0.0.0:9093",
    "KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka_broker:9092,PLAINTEXT_HOST://localhost:29092",
    "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT",
    "KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka_broker:9093",
    "KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER",
    "KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT",
    "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1",
    # The image script specifically looks for CLUSTER_ID without the KAFKA_ prefix in some versions
    "CLUSTER_ID=MkU3OEVBNTcwNTJDRDRCMz",
    "KAFKA_LOG_DIRS=/var/lib/kafka/data"
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

# --- Kafka Web UI (Redpanda Console) ---
resource "docker_container" "kafka_ui" {
  name  = "kafka_ui"
  image = "redpandadata/console:latest"

  ports {
    internal = 8080
    external = 8083
  }

  env = [
    "KAFKA_BROKERS=kafka_broker:9092"
  ]

  networks_advanced {
    name = docker_network.my_shared_network.name
  }

  depends_on = [docker_container.kafka]
}

# --- LiteLLM Proxy Service ---
resource "docker_container" "litellm" {
  name  = "litellm_proxy"
  image = "ghcr.io/berriai/litellm:main-latest"

  ports {
    internal = 4000
    external = 4000
  }

  volumes {
    host_path      = "${path.cwd}/litellm/config.yaml"
    container_path = "/app/config.yaml"
  }

  # Ensure it uses the config and remains quiet for production logs
  command = ["--config", "/app/config.yaml", "--port", "4000"]

  env = concat(
    [
      "LITELLM_MASTER_KEY=${var.LITELLM_MASTER_KEY}",
      "UI_USERNAME=${var.LITELLM_ADMIN_USERNAME}",
      "UI_PASSWORD=${var.LITELLM_ADMIN_PASSWORD}",
      "DATABASE_URL=postgresql://${var.POSTGRES_DOMAIN_DATA_USER}:${var.POSTGRES_DOMAIN_DATA_PASSWORD}@${local.postgres_data_host}:5432/${var.POSTGRES_DOMAIN_DATA_DB}",
      "LITELLM_SALT_KEY=${var.LITELLM_SALT_KEY}",
    ],
    [for k, v in var.llm_api_keys : "${k}=${v}"]
  )

  networks_advanced {
    name = docker_network.my_shared_network.name
  }
  depends_on = [docker_container.postgres_data]

  restart = "unless-stopped"
}

# --- Open WebUI Service ---
resource "docker_container" "open_webui" {
  name  = "open_webui"
  image = "ghcr.io/open-webui/open-webui:main"

  ports {
    internal = 8080
    external = 3000
  }

  env = [
    "OPENAI_API_BASE_URL=http://litellm_proxy:4000/v1",
    "OPENAI_API_KEY=sk-not-required", # LiteLLM handles the real keys
    "ENABLE_OLLAMA=false",
    "WEBUI_SECRET_KEY=${var.OPEN_WEBUI_SECRET_KEY}"
  ]

  volumes {
    volume_name    = docker_volume.open_webui_data.name
    container_path = "/app/backend/data"
  }

  networks_advanced {
    name = docker_network.my_shared_network.name
  }

  restart    = "unless-stopped"
  depends_on = [docker_container.litellm]
}

resource "docker_container" "ngrok" {
  image = "ngrok/ngrok:latest"
  name  = "ngrok"

  volumes {
    host_path      = "${path.cwd}/ngrok/config.yaml"
    container_path = "/etc/ngrok.yml"
  }

  env = [
    "NGROK_AUTHTOKEN=${var.NGROK_AUTHTOKEN}"
  ]


  command = ["start", "--all", "--config", "/etc/ngrok.yml"]

  ports {
    internal = 4040
    external = 4040
  }

  networks_advanced {
    name = docker_network.my_shared_network.name
  }

  restart    = "unless-stopped"
  depends_on = [docker_container.open_webui]
}

# --- Outputs ---

output "data_platform_access" {
  description = "Connection URLs for the main services and databases."
  value = {
    airflow_webserver    = "http://localhost:8080"
    superset_ui          = "http://localhost:8088"
    spark_master_ui      = "http://localhost:8081"
    trino_ui             = "http://localhost:8082"
    minio_console        = "http://localhost:9001"
    ollama_api           = "http://localhost:11434"
    postgres_metadata_db = "localhost:${var.POSTGRES_METADATA_PORT}"
    postgres_data_db     = "localhost:${var.POSTGRES_DOMAIN_DATA_PORT}"
    kafka_ui             = "http://localhost:8083"
    kafka_broker         = "http://localhost:9092"
  }
}

output "initial_credentials" {
  description = "Initial login credentials for Airflow and Superset."
  value = {
    airflow_user      = var._AIRFLOW_WWW_USER_USERNAME
    airflow_password  = var._AIRFLOW_WWW_USER_PASSWORD
    superset_user     = var.SUPERSET_ADMIN_USERNAME
    superset_password = var.SUPERSET_ADMIN_PASSWORD
    # Domain Data DB credentials
    domain_data_user     = var.POSTGRES_DOMAIN_DATA_USER
    domain_data_password = var.POSTGRES_DOMAIN_DATA_PASSWORD
  }
  sensitive = true
}
