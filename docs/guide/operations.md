# Operations

Commands below use the default container names. With `CONTAINER_PREFIX` set, prefix them
accordingly (`<prefix>cxo-db`).

## Upgrading

1. Read the CxO release notes for the target version, including its migration guide. They say
   whether an upgrade needs anything beyond new images.
2. [Back up](#backup-and-restore).
3. Check out the new release, so compose files and default settings match its images:

   ```bash
   git fetch --tags
   git checkout 26q4
   ```

   With your changes kept outside the tracked files ([Configuration](configuration.md)), this
   has nothing to merge. If git refuses because of local changes, a tracked file was edited;
   move that change into your override directory.
4. Set the same tag in `.env` (`CXO_TAG=26q4`) and start with fresh images:

   ```bash
   ./startup.sh all --pull=always
   ```

   or, with your own override directory, `../cxo-site/up.sh up -d --pull always`.

Compose recreates only the containers whose image or configuration changed.

## Starting and stopping

```bash
./startup.sh all           # start, or apply changed images and compose files
./stop.sh                  # stop and remove the containers; volumes stay
docker restart cxo-service-catalog-management    # one container
```

`./stop.sh` removes everything `docker-compose.yml` defines, whatever target started it. The
monitoring containers are not part of that; stop them with

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down
```

## Logs

Logs, metrics and traces are in **Grafana** at http://localhost:43000, starting from the
*CxO Home* dashboard. Every CxO service sends structured logs to Loki through the OpenTelemetry
Collector: search, filter by service, follow a request across services by its trace id.

Container output works too:

```bash
docker logs -f --tail 200 cxo-service-order-management
```

## Backup and restore

Data lives in Docker volumes. Back up the databases with the stack running:

```bash
docker exec cxo-db pg_dumpall -U postgres | gzip > cxo-$(date +%F).sql.gz
docker exec cxo-conductordb pg_dumpall -U postgres | gzip > conductor-$(date +%F).sql.gz
```

| Data | Where | Back up with |
|---|---|---|
| CxO services | `cxo-db` (`cxo-db-postgres` with `--with-pgbouncer`) | `pg_dumpall -U postgres` |
| Conductor | `cxo-conductordb` | `pg_dumpall -U postgres` |
| CxMaestro | `cxo-maestrodb` | `pg_dumpall -U maestro` |
| Keycloak users, clients, secrets | volume `keycloak_db` | a copy of the volume, or a realm export from the admin console |

To restore the CxO databases, start from an empty database volume so the dump can create them:

```bash
./stop.sh
./db-drop-all.sh                       # removes the CxO database volume; asks first
./db-restore.sh cxo-2026-11-13.sql.gz  # loads the dump into cxo-db
./startup.sh all
```

`db-restore.sh` loads into the container named `cxo-db`. With PgBouncer or a container prefix,
pipe the dump in yourself:

```bash
gunzip -c cxo-2026-11-13.sql.gz | docker exec -i cxo-db-postgres psql -U postgres
```

## Disk space

What grows without a limit by default:

| What | Default | To limit it |
|---|---|---|
| Container output | most containers keep it all | Set `log-opts` (`max-size`, `max-file`) for the `json-file` driver in Docker's `daemon.json`; applies to recreated containers. |
| Loki | 7 days | `retention_period` in `files/monitoring/loki/loki.yml`. Size the volume for it: about 500 bytes per log line after compression. |
| Tempo | 48 hours | `block_retention` in `files/monitoring/tempo/tempo.yml`. |
| Prometheus | 15 days (Prometheus default) | Add `--storage.tsdb.retention.time` to its command. |

Check usage with `docker system df -v`.

## Starting over

```bash
./db-drop-all.sh                                   # CxO databases only; asks first
docker compose -f docker-compose.yml down --volumes # every container and volume of the stack
```

The second command removes what `docker-compose.yml` defines (add
`-f docker-compose.monitoring.yml` for the monitoring data). It also removes Keycloak's data, the engine's database and Kafka. The next start
imports the realm again with its default users and secrets.
