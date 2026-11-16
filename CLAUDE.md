# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

cx-orchestrator-composer is a Docker Compose orchestration project for CxO (Codaxy Orchestrator), built on TM Forum Open APIs. It composes ~30 microservices (TMF APIs, workflow engines, portals, infrastructure) into a local development stack. There is no application source code here — only compose files, configuration, and helper scripts.

## Common Commands

All commands have both `.bat` (Windows) and `.sh` (bash) variants. Use the `.sh` scripts when working in bash.

### Stack Management

```bash
# First-time setup (requires sudo/admin — adds hosts file entries)
sudo ./setup.sh

# Generate HTTPS certificates (required before starting portals)
./startup.sh gencert          # via container
./startup.sh gencert-dotnet   # via dotnet dev-certs

# Start various subsets of the stack
./startup.sh all              # everything (requires certs)
./startup.sh infrastructure   # databases + orchestration engine + keycloak + kafka + redis + monitoring
./startup.sh services         # infrastructure + all microservices + API gateway
./startup.sh services.tmf     # infrastructure + TMF + util services only
./startup.sh db               # PostgreSQL + pgAdmin only
./startup.sh conductor        # Conductor workflow engine only
./startup.sh keycloak         # Keycloak SSO only
./startup.sh kafka            # Kafka + Kafka UI + kafka-exporter only
./startup.sh monitoring       # Prometheus + Grafana + Loki + Tempo + OTel Collector + postgres exporters

# Pass extra docker compose flags after the subcommand
./startup.sh all --pull=always

# Stop all containers
./stop.sh

# Database operations
./db-restore.sh <dump.sql|dump.sql.gz>   # restore SQL dump into cxo-db
./db-drop-all.sh                          # DESTRUCTIVE: drops and recreates all DB volumes

# Factory reset (DESTRUCTIVE: removes all containers and volumes, then git-cleans the repo)
./factory-reset.sh
```

### PgBouncer Support

Add `--with-pgbouncer` to any startup command to use PgBouncer as connection pooling middleware. If the DB volume already exists, run `scripts/postgres/migrate-to-pgbouncer.sh` first.

### Pinning Image Versions

Override image tags per-service or globally via environment variables or `.env` file:
```bash
CXO_TAG=25m06 CXO_RESOURCE_POOL_MANAGEMENT_TAG=25w25 ./startup.sh services
```

Tag variable pattern: `CXO_<UPPER_SNAKE_SERVICE_NAME>_TAG` falls back to `CXO_TAG`, then `latest`.

## Architecture

### Compose File Hierarchy

The compose files use Docker Compose `include` directives to form a layered dependency tree:

- **`docker-compose.yml`** (full stack) → management + portals
  - **`docker-compose.portals.yml`** → services (Admin Portal, Engineering Portal, MCP Tools)
    - **`docker-compose.services.yml`** → infrastructure + all service groups + API gateway
      - **`docker-compose.infrastructure.yml`** → db + orchestration engine (Conductor or CxMaestro) + keycloak + caching + kafka + network. startup.sh adds `docker-compose.monitoring.yml` to the stack targets by default; `--without-monitoring` leaves it out.
      - **`docker-compose.services.tmf.yml`** — 16 TMF API microservices
      - **`docker-compose.services.engines.yml`** — workflow engines (Service Ordering, Resource Ordering, Service Activation)
      - **`docker-compose.services.util.yml`** — CxO Settings, Locking Management, Resource Manager
      - **`docker-compose.api-gateway.yml`** — TMF API Gateway (YARP-based)

Only product services belong here: no demo services and no environment-specific configuration. See CONTRIBUTING.md.

Infrastructure sub-stacks:
- **`docker-compose.db.yml`** → `db.pg.yml` + `network.yml`
- **`docker-compose.db.pg.yml`** — PostgreSQL 15 on port 40100, pgAdmin on 40250
- **`docker-compose.conductor.yml`** — Conductor server on 48081 (UI on 45000) with its own PostgreSQL
- **`docker-compose.keycloak.yml`** — Keycloak 26 on port 8080
- **`docker-compose.kafka.yml`** — Confluent Kafka on 29092, Conduktor UI on 8086, kafka-exporter (internal only, no host port — scraped by the OTel Collector for the CxO Kafka Grafana dashboard)
- **`docker-compose.caching.yml`** — Redis on 63790
- **`docker-compose.monitoring.yml`** — Prometheus on 9090, Grafana on 43000, Loki on 3100, Tempo on 3200, OTel Collector on 4317/4318 (the platform's scrape + OTLP ingest point), postgres exporters

### Networking

All containers join a shared `cxo_network` bridge network. Services reference each other by container alias (e.g. `cxo-db`, `cxo-kafka`, `cxo-conductor`).

### Configuration

- **`settings/local/`** — appsettings JSON files mounted as Docker secrets into each service container at `/app/appsettings-mounted/0/appsettings.json`
- **`data/keycloak/`** — Keycloak realm import data and custom themes
- **`files/conductor/`** — Conductor `config.properties`
- **`files/monitoring/`** — Prometheus, Loki, Tempo configs + Grafana provisioning (datasources, dashboards, alerting)
- **`.env`** (gitignored) — optional overrides for `CONTAINER_PREFIX` and `COMPOSE_PROJECT_NAME` (to run multiple stacks without container name collisions)

### Key Port Ranges

| Range | Purpose |
|-------|---------|
| 40100-40250 | Database infrastructure (PostgreSQL, pgAdmin) |
| 40300-40304 | Portals (Admin, Engineering, Resource Manager) |
| 40600 | TMF API Gateway |
| 40629-40720 | TMF microservice APIs |
| 45000 | Conductor UI or CxMaestro portal |
| 48081 | Conductor API |
| 50211-50223 | gRPC endpoints (HTTP/2) for engines |
| 8080 | Keycloak |
| 8086 | Kafka UI |
| 29092 | Kafka external listener |
| 63790 | Redis |
| 43000 | Grafana |
| 3100 | Loki |
| 3200 | Tempo API |
| 4317, 4318 | OTel Collector (OTLP gRPC, OTLP HTTP) |
| 9090 | Prometheus |

### Hosts File Requirement

The setup script adds `local.keycloak.codaxy-cxo` and `local.codaxy-cxo` pointing to `127.0.0.1` for SSO resolution.

## Conventions

- **EditorConfig**: JSON files use 2-space indentation
- **Docker Compose overrides**: `docker-compose.override.yml` and `docker-compose.override.*.yml` are gitignored (except `docker-compose.override.sso.yml`) — use these for local customizations
- All microservice images come from `ghcr.io/codaxy/` registry
- Container names are prefixed with `${CONTAINER_PREFIX:-}cxo-` to support multiple parallel stacks

## Windows Port Conflict

If you see `bind: An attempt was made to access a socket in a way forbidden`, restart the Windows Host Networking Service: `net stop hns` (as Administrator), then retry.
