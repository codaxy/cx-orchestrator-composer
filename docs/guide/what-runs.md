# What runs

## Startup targets

`./startup.sh <target> [options] [docker compose flags]` starts one slice of the stack. Each
target includes what it depends on.

| Target | Starts |
|---|---|
| `all` | Everything below, plus the Admin Portal, Engineering Portal, MCP tools, Portainer and autoheal. Needs `certs/aspnetapp.pfx`. |
| `services` | `infrastructure` + all TMF services, the engines, the utility services (Settings, Locking, Audit, Resource Manager) and the TMF API gateway. No Admin or Engineering Portal. |
| `services.tmf` | `infrastructure` + the TMF and utility services. No engines, no gateway. |
| `infrastructure` | PostgreSQL + pgAdmin, the orchestration engine, Keycloak, Redis, Kafka + Kafka UI, and monitoring. |
| `db`, `caching`, `data` | PostgreSQL + pgAdmin; Redis; both. |
| `keycloak`, `kafka`, `logging` | One component each. |
| `conductor`, `maestro` | One orchestration engine on its own. |
| `monitoring` | Prometheus, Grafana, Loki, Tempo, the OpenTelemetry Collector and the Postgres exporters. |
| `gencert`, `gencert-dotnet` | Generate the portal certificate; see [Quick start](quick-start.md#3-generate-the-portal-certificate). |

The Resource Manager serves HTTPS too, so `services` also needs the certificate even though only
`all` checks for it.

Anything after the options goes to `docker compose up`, for example
`./startup.sh all --pull=always`.

## Options

| Option | Effect |
|---|---|
| `--without-monitoring` | Leaves the monitoring stack out. `all`, `services`, `services.tmf` and `infrastructure` include it by default. |
| `--with-maestro` | Runs CxMaestro instead of Netflix Conductor. Same as `CXO_ORCHESTRATOR=maestro`. |
| `--with-merged[=sm,rm,cdm]` | Runs the merged Service Management, Resource Management and Common Data Management images in place of their individual services. `all` and `services` only. |
| `--with-pgbouncer` | Puts PgBouncer in front of PostgreSQL. |

### Orchestration engine

Conductor is the default. Only one engine runs at a time; both publish ports 48081 (API) and
45000 (UI), and CxMaestro answers under Conductor's network name, so no service settings change.

Each service registers its workflow and task definitions with the engine **when it starts**. After
switching engines on a running stack, the new engine is empty until the services restart:

```bash
./startup.sh all --with-maestro
docker compose -f docker-compose.yml restart
```

Switching back finds the first engine's data where it was left: its volume is kept.

The services that wait on the engine get that dependency from the `docker-compose.*.depends.<engine>.yml`
files, which `startup.sh` adds. Running `docker compose` by hand without them starts those services
without waiting for the engine, with no warning. Use `startup.sh`, or pass the same files (see
[Configuration](configuration.md#overriding-settings-and-containers)).

### Merged images

With `--with-merged`, each group runs as one container that takes over its services' network
names and host ports, so nothing that calls them needs reconfiguring, and every module keeps its
own database. Leaving a group out on a later run switches it back to the individual services.

Settings for the merged images are in
`settings/local/appsettings.{ServiceManagement,ResourceManagement,CommonDataManagement}.json`.

### PgBouncer

On a fresh installation, `--with-pgbouncer` creates the databases and the pooler user itself. If
the stack has already run without it, migrate the existing volume first:

```bash
scripts/postgres/migrate-to-pgbouncer.sh
```

Use the option on every later start; starting without it reverts to direct connections.

## Ports

Every port is published on all host interfaces. See
[Running on a shared host](deploying-to-a-server.md#restrict-what-is-reachable) before using the
stack on a machine others can reach.

**Portals and APIs**

| Component | Port |
|---|---|
| Admin Portal | 40300 (HTTPS) |
| Engineering Portal | 40302 (HTTPS) |
| Resource Manager | 40304 (HTTPS) |
| MCP tools | 40303 |
| TMF API gateway | 40600 |

**Services** (HTTP; each serves `/swagger` and `/health`)

| Service | Port | Service | Port |
|---|---|---|---|
| Customer Management | 40629 | Resource Catalog Management | 40634 |
| Party Management | 40632 | Resource Inventory Management | 40639 |
| Service Catalog Management | 40633 | Service Order Management | 40641 |
| Service Inventory Management | 40638 | Resource Order Management | 40652 |
| Party Role Management | 40669 | Resource Pool Management | 40685 |
| User Roles and Permissions | 40672 | Event Management | 40688 |
| Geographic Address Management | 40673 | Digital Identity | 40720 |
| Geographic Site Management | 40674 | CxO Settings | 40210 |
| Geographic Location Management | 40675 | CxO Audit | 40230 |

**Engines** (HTTP and gRPC)

| Engine | HTTP | gRPC |
|---|---|---|
| Service Ordering Engine | 40211 | 50211 |
| Resource Ordering Engine | 40223 | 50223 |
| Service Activation Management | 40640 | 50640 |
| Locking Management | 40222 | 50222 |

**Infrastructure**

| Component | Port |
|---|---|
| PostgreSQL | 40100 |
| pgAdmin | 40250 |
| Keycloak | 8080 (management: 49000) |
| Conductor or CxMaestro | 48081 (API), 45000 (UI) |
| Kafka (external listener) | 29092 |
| Kafka UI | 8086 |
| Redis | 63790 |
| Portainer | 9443 (HTTPS), 8000 |
| Grafana | 43000 |
| Prometheus | 9090 |
| Loki / Tempo | 3100 / 3200 |
| OpenTelemetry Collector | 4317 (gRPC), 4318 (HTTP) |

## Default sign-ins

These are public placeholders. Change them before anyone else can reach the stack.

| Where | User | Password |
|---|---|---|
| Portals (Keycloak realm `Codaxy`) | `test` | `test` |
| Keycloak admin console | `admin` | `admin` |
| PostgreSQL | `postgres` | `postgres` |
| pgAdmin | `codaxy@codaxy.com` | `codaxy` |
| Grafana | `admin` | `admin` |
| Kafka UI | `admin@admin.com` | `Admin123!` |

## Where things are in the repository

| Path | Holds |
|---|---|
| `docker-compose*.yml` | One file per slice of the stack; `docker-compose.yml` is the full stack. |
| `settings/local/` | One `appsettings.<Service>.json` per service: connection strings, service URLs, sign-in. |
| `data/keycloak/` | The `Codaxy` realm imported on Keycloak's first start, and the login theme. |
| `files/` | Configuration for Conductor, CxMaestro, PostgreSQL, PgBouncer and the monitoring stack. |
| `certs/` | The portal certificate (not committed). |
| `.env` | Your own variables (not committed); see [Configuration](configuration.md). |
