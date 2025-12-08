from __future__ import annotations

import logging
from datetime import datetime
from pathlib import Path
from typing import Any

from airflow.decorators import dag, task  # pyright: ignore[reportUnknownVariableType]
from airflow.providers.amazon.aws.hooks.s3 import S3Hook
from mypy_boto3_s3.service_resource import Object as S3ResourceObject

# --- Configuration ---
# Set the maximum size for a partition folder (50 MB)
MAX_PARTITION_SIZE_MB = 50
MAX_PARTITION_SIZE_BYTES = MAX_PARTITION_SIZE_MB * 1024 * 1024

LANDING_BUCKET = "raw-files"
PROCESSED_BUCKET = "processed-data"
S3_CONN_ID = "minio_s3_conn"
FILE_PREFIX = "uploads/" # Only look for files in this "folder" within the landing bucket

# Set logging level for clarity
log: logging.Logger = logging.getLogger(__name__)

# --- Helper Function ---
# Note: This function calculates the *approximate* size by summing object sizes, 
# which is slightly faster than making a head_object call for every file.
def get_partition_size(s3_hook: S3Hook, partition_prefix: str) -> int:
    """Calculates the total size of all objects under a given S3 prefix."""
    total_size: int = 0
    
    # List all objects under the given prefix (e.g., 'processed-data/dt=2025-12-08/part-01/')
    # The 'list_keys' method returns only the object keys (paths).
    object_keys: list[Any] = s3_hook.list_keys(
        bucket_name=PROCESSED_BUCKET, 
        prefix=partition_prefix, 
    )
    
    # We must call head_object for each key to get its size
    if object_keys:
        for key in object_keys:
            try:
                # 'get_key' performs a HEAD request to get metadata, including size
                obj_metadata: S3ResourceObject = s3_hook.get_key(key, bucket_name=PROCESSED_BUCKET)
                if obj_metadata:
                    total_size += obj_metadata.content_length
            except Exception as e:
                log.warning(f"Could not get size for key {key}: {e}")

    return total_size

# --- Airflow DAG Definition ---

@dag(
    schedule="@hourly",
    start_date=datetime(2025, 12, 1),
    catchup=False,
    tags=["minio", "partitioning", "data-lake"],
)
def minio_partitioning_pipeline():
    
    @task
    def process_and_partition_files():
        """
        1. Lists files in the landing zone.
        2. Calculates the current partition size.
        3. Moves files to the correct date and size-based partition.
        """
        s3_hook = S3Hook(aws_conn_id=S3_CONN_ID)
        
        # 1. Check for files in the landing zone
        log.info(f"Checking for new files in {LANDING_BUCKET}/{FILE_PREFIX}")
        files_to_process: list[Any] = s3_hook.list_keys(
            bucket_name=LANDING_BUCKET, 
            prefix=FILE_PREFIX, 
        )
        
        if not files_to_process:
            log.info("No new files found. Exiting task.")
            return
            
        log.info(f"Found {len(files_to_process)} files to process.")

        # Determine the current date-based partition prefix: 'dt=YYYY-MM-DD/'
        current_date_partition = f"dt={datetime.now().strftime('%Y-%m-%d')}/"
        
        # Start looking for the current size-based partition (starts at part-01)
        part_index = 1
        current_partition_key_prefix = f"{current_date_partition}part-{part_index:02d}/"
        
        # 2. Find the current available partition based on size limit
        while True:
            # Calculate the size of the current partition candidate
            current_size = get_partition_size(s3_hook, current_partition_key_prefix)
            
            log.info(f"Checking partition {current_partition_key_prefix}: Current Size = {current_size / (1024 * 1024):.2f} MB")

            if current_size < MAX_PARTITION_SIZE_BYTES:
                # Found a partition with available space
                break
            
            # If the partition is full, increment and check the next one
            part_index += 1
            current_partition_key_prefix = f"{current_date_partition}part-{part_index:02d}/"
            
        # 3. Process and move all pending files
        successful_moves = 0
        
        for old_key in files_to_process:
            # Skip objects that represent folders/prefixes if MinIO created them
            if old_key.endswith('/'):
                continue
                
            # Use the filename component only
            filename = Path(old_key).name
            
            # Create the final destination key
            new_key = current_partition_key_prefix + filename
            
            # Perform the move (Copy then Delete)
            log.info(f"Moving {old_key} to {new_key}")
            
            s3_hook.copy_object(
                source_bucket_key=old_key,
                dest_bucket_key=new_key,
                source_bucket_name=LANDING_BUCKET,
                dest_bucket_name=PROCESSED_BUCKET,
            )
            s3_hook.delete_objects(bucket=LANDING_BUCKET, keys=[old_key])
            successful_moves += 1

            # OPTIONAL: Recalculate size and potentially roll over the partition 
            # after every move, if the file is large and might push the current partition over the limit
            # For simplicity, we assume the initial check is sufficient for all small files.

        log.info(f"Successfully moved {successful_moves} files to partition {current_partition_key_prefix}")

    # Define the task dependencies
    process_and_partition_files()

minio_partitioning_dag = minio_partitioning_pipeline()