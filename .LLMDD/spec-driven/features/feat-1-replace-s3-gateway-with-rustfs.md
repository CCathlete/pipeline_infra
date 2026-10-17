# feat-1: replace-s3-gateway-with-rustfs

- Status: Implemented
- Created: 2026-10-17
- Feature ID: feat-1-replace-s3-gateway-with-rustfs

## Synopsis

Motivation: commit de5fe03 ("trim data platform to newspipe needs and tune for
small box") swapped MinIO out for a LocalStack S3 gateway, recording the reason
as "MinIO (unpullable)". That is still true: `docker manifest inspect
minio/minio:latest` returns `unauthorized: authentication required`, so the
image cannot be pulled on this host and MinIO is not reachable from Docker Hub
or quay.io either. But LocalStack is an AWS API emulator, not storage. It is
the wrong tool for a bronze layer that is meant to be a real data lake: it held
680K of nothing, the `lakehouse` bucket did not exist, and nothing had ever been
written to it. LocalStack was also the memory-heavier of the two at 196 MiB,
which inverts the "small box" rationale that motivated the swap.

Two S3-compatible object stores pull without authentication on this host:
SeaweedFS (`chrislusf/seaweedfs`) and RustFS (`rustfs/rustfs`). RustFS was
chosen because it serves S3 on :9000, matching the layout newspipe was
originally written against, and ships a health endpoint the rest of the stack
can gate on.

Scope (in):
- `docker_container.localstack` replaced by `docker_container.rustfs` on
  :9000 (S3 API) and :9001 (console), with a healthcheck on `/health`
- `docker_volume.localstack_data` replaced by `docker_volume.rustfs_data`,
  retaining `prevent_destroy`
- A one-shot `rustfs_init` container that waits for the S3 API and ensures the
  `lakehouse` bucket exists, replacing LocalStack's `awslocal` affordance
- `AIRFLOW_CONN_AWS_DEFAULT` repointed from `http://localstack:4566` to
  `http://rustfs:9000`, with credentials moved out of the literal into
  variables
- The Trino container's `depends_on` retargeted from `localstack` to `rustfs`
- `variables.tf`: `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`,
  `RUSTFS_IMAGE_NAME`, `LAKEHOUSE_BUCKET`
- The `data_platform_access` output: `localstack_s3` replaced by `rustfs_s3`
  and `rustfs_console`

Scope (out):
- Trino's S3 catalog configuration. `trino/etc/catalog/hive.properties` still
  carries only `connector.name=hive` and `hive.metastore.uri`, so Trino cannot
  read the lakehouse. This predates the swap and is tracked separately.
- Credential rotation. `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` default to
  the inherited `minioadmin` values so the Airflow connection and any existing
  newspipe configuration keep working. They are now `sensitive` variables and
  should be rotated before any non-local use.
- The `rustfs_init` plan churn: a container that exits immediately drops out of
  the docker provider's state view, so every `terraform plan` proposes
  re-creating it. Harmless because bucket creation is idempotent, but it means
  the plan is never empty. Converting it to `terraform_data` with a
  `local-exec` provisioner would fix it and is not done here.
- newspipe application wiring. The S3 endpoint, `hadoop-aws` dependency and
  Spark `fs.s3a.*` settings are newspipe-side work.

## Implementation status

Implemented. Applied with `terraform apply` (3 resources added in two staged,
target-scoped applies, then a full apply: 6 added, 0 changed, 4 destroyed).

This is a retroactive spec: the change was made under an in-session Advisor
approval token and applied directly, not decomposed into CUs. There is
therefore no ITR directory and no per-CU feedback for this feature.

Verification at time of writing: `terraform validate` reports a valid
configuration; `terraform fmt -check` is clean; the RustFS container reports
healthy; a put/get/delete round trip through the S3 API succeeds; the
`lakehouse` bucket is present on the volume at `/data/lakehouse` owned by
uid 10001.

## Acceptance criteria

1. `docker ps` shows a container named `rustfs` running healthy, publishing
   :9000 and :9001.
2. `GET http://localhost:9000/health` returns HTTP 200.
3. `GET http://localhost:9001/rustfs/console/health` returns HTTP 200.
4. The `lakehouse` bucket exists on the RustFS volume and an object written to
   it reads back byte-identical through the S3 API.
5. No container named `localstack` exists and no `localstack_data` volume
   exists.
6. `AIRFLOW_CONN_AWS_DEFAULT` in the running Airflow container carries
   `http://rustfs:9000` as both `host` and `endpoint_url`.
7. The Trino container's `depends_on` references `docker_container.rustfs`.
8. `docker_volume.rustfs_data` carries `prevent_destroy = true`.
9. The `data_platform_access` output exposes `rustfs_s3` and `rustfs_console`
   and no longer exposes `localstack_s3`.
10. `terraform validate` succeeds and `terraform fmt -check` reports no
    changes.
11. The containers in state drift before this change resolve correctly:
    `hive_metastore` and `sqlite_metastore_db`, both of which had been
    `Exited (255)`, are running afterwards, and `airflow_init`, a one-shot job
    whose success is an exit rather than a running process, exits 0.

## Tests

- `terraform validate` — reports "Success! The configuration is valid."
  (criterion 10)
- `terraform fmt -check -diff data_platform.tf variables.tf` — prints no
  diff (criterion 10)
- `terraform plan` — the only proposed change is re-creating `rustfs_init`;
  `localstack` and `localstack_data` appear in no section (criteria 5, 9)
- `terraform output data_platform_access` — shows `rustfs_s3` and
  `rustfs_console` (criterion 9)
- `docker ps -a --filter name=rustfs --format '{{.Status}}'` — contains
  `(healthy)` (criterion 1)
- `curl -s -o /dev/null -w '%{http_code}' http://localhost:9000/health` —
  prints `200` (criterion 2)
- `curl -s -o /dev/null -w '%{http_code}'
  http://localhost:9001/rustfs/console/health` — prints `200` (criterion 3)
- `docker ps -a --filter name=localstack` — prints nothing, and
  `docker volume ls` lists neither `localstack_data` nor a LocalStack volume
  (criterion 5)
- `docker inspect airflow_webserver --format '{{range .Config.Env}}...'` |
  grep `AIRFLOW_CONN_AWS_DEFAULT` — shows `http://rustfs:9000` (criterion 6)
- `grep -n -A2 depends_on data_platform.tf | grep rustfs` — prints at least
  two matches, covering the Trino container and `rustfs_init` (criterion 7)
- S3 round trip, from the host:

  ```
  docker run --rm --network my_shared_network --entrypoint /bin/sh \
    -e AWS_ACCESS_KEY_ID=minioadmin \
    -e AWS_SECRET_ACCESS_KEY=minioadminpassword \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli:latest -c '
    set -e
    E="--endpoint-url http://rustfs:9000"
    echo hello | aws $E s3 cp - s3://lakehouse/_probe.txt
    aws $E s3 cp s3://lakehouse/_probe.txt -
    aws $E s3 rm s3://lakehouse/_probe.txt'
  ```

  Expect the echoed object back and exit 0 (criterion 4). The `--entrypoint
  /bin/sh` is required: `amazon/aws-cli` sets an `aws` entrypoint, so without
  it the shell command is passed to `aws` as arguments.
- `docker exec rustfs ls -la /data` — shows a `lakehouse` directory owned by
  `rustfs` (criterion 4)
- `docker ps --filter name=hive_metastore --filter name=sqlite
  --format '{{.Names}}\t{{.Status}}'` — both report `Up` (criterion 11)
- `docker inspect airflow_init --format '{{.State.ExitCode}}'` — prints `0`.
  `airflow_init` runs `airflow db init` then exits, so `Exited (0)` is the
  passing state here; asserting it reports `Up` would be wrong (criterion 11)
