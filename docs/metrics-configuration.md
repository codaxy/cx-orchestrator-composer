# CxO Metrics Configuration

Reference documentation for the CxO monitoring stack: retention settings, scrape intervals, storage configuration, and recommended production values.

## Monitoring Stack Overview

The CxO platform ships a Grafana-based monitoring stack via `cx-orchestrator-composer`:

| Component  | Image                    | Port  | Purpose                     |
|------------|--------------------------|-------|-----------------------------|
| Prometheus | `prom/prometheus:v3`  | 9090  | Metrics collection and query |
| Grafana    | `grafana/grafana:13.0`  | 43000 | Dashboards, alerting, log/trace exploration |
| Loki       | `grafana/loki:3`          | 3100  | Log aggregation              |
| Tempo      | `grafana/tempo:2.7.2`    | 3200, 4317, 4318 | Distributed tracing (OTLP) |

**Starting the stack:**

```bash
cd cx-orchestrator-composer
./startup.sh monitoring          # monitoring stack only
./startup.sh services                     # services + monitoring (default)
```

Configuration files live under `files/monitoring/`.

## Non-PROD vs PROD Retention

| Setting | Non-PROD (current) | Recommended PROD |
|---------|-------------------|------------------|
| **Prometheus retention (time)** | ~15 days (image default) | 30 days |
| **Prometheus retention (size)** | Unlimited (default) | Consider 50-100 GB cap |
| **Prometheus scrape interval** | 15s | 15s (no change) |
| **Loki log retention** | 168h (7 days) | 720h (30 days) |
| **Loki compaction interval** | 10m | 10m (no change) |
| **Tempo trace retention** | 48h (2 days) | 720h (30 days) |

### Disk Space Estimates (PROD, 30-day retention)

These are rough estimates for a full platform deployment (~27 services):

| Component  | Estimated Disk (30 days) | Notes |
|------------|-------------------------|-------|
| Prometheus | 10-30 GB | Depends on metric cardinality and label count |
| Loki       | 20-60 GB | Depends on log volume; Debug level increases 5-10x |
| Tempo      | 5-15 GB  | Depends on trace sampling rate and request volume |

## How to Apply PROD Settings

### Prometheus

Add the `--storage.tsdb.retention.time` flag to the Prometheus command in your compose override:

```yaml
# docker-compose.monitoring.prod.yml (override)
services:
  prometheus:
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=30d"
      - "--storage.tsdb.retention.size=50GB"
```

**Key flags:**
- `--storage.tsdb.retention.time=30d` -- keep data for 30 days
- `--storage.tsdb.retention.size=50GB` -- cap disk usage (whichever limit is hit first)
- `--storage.tsdb.path=/prometheus` -- data directory (default, matches volume mount)

### Loki

Edit `loki.yml` or mount a production override:

```yaml
limits_config:
  retention_period: 720h   # 30 days

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  delete_request_cancel_period: 10m
  delete_request_store: filesystem
```

The `retention_enabled: true` flag under `compactor` is required for retention to take effect. This is already set in the Non-PROD config.

### Tempo

Edit `tempo.yml` or mount a production override:

```yaml
compactor:
  compaction:
    block_retention: 720h   # 30 days
```

### Docker Compose Override Example

For production deployments, create a `docker-compose.monitoring.prod.yml` override file:

```yaml
services:
  prometheus:
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=30d"
      - "--storage.tsdb.retention.size=50GB"

  loki:
    volumes:
      - ./files/monitoring/loki/loki-prod.yml:/etc/loki/local-config.yaml:ro

  tempo:
    volumes:
      - ./files/monitoring/tempo/tempo-prod.yml:/etc/tempo/tempo.yml:ro
```

Apply with: `docker compose -f docker-compose.monitoring.yml -f docker-compose.monitoring.prod.yml up -d`

## Scrape Configuration (OTel Collector)

Prometheus itself only self-scrapes; **every platform target is scraped by the OTel Collector** (`files/monitoring/otel-collector/config.yml`, `prometheus` receiver), which stamps the `cxo_instance`/`environment` resource attributes and pushes to Prometheus via `remote_write`. To add a scrape target, edit the collector config — not `prometheus.yml`.

**Global settings** (collector `prometheus` receiver):

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
```

### Scrape Jobs

| Job | Scheme | Port | Targets |
|-----|--------|------|---------|
| `cxo-services-http` | HTTP | 8080 | TMF services, engines, gateway, locking, settings (22 targets via Docker DNS) |
| `cxo-services-https` | HTTPS (skip verify) | 8081 | Portals: admin-portal, engineering-portal, resource-manager |
| `cxo-conductor` | HTTP | 8080 (`/actuator/prometheus`) | Conductor server |
| `cxo-postgres` | HTTP | 9187 | postgres-exporter (application DB) + postgres-exporter-conductor |
| `cxo-kafka` | HTTP | 9308 | kafka-exporter (broker, topic/partition offsets, consumer-group lag) |

### Full Target List (`cxo-services-http`)

| Target (Docker DNS) | Service Label |
|---------------------|---------------|
| `partymanagement:8080` | cxo-party-management |
| `digitalidentity:8080` | cxo-digital-identity |
| `partyrolemanagement:8080` | cxo-party-role-management |
| `customermanagement:8080` | cxo-customer-management |
| `userrolesandpermissions:8080` | cxo-user-roles-and-permissions |
| `servicecatalogmanagement:8080` | cxo-service-catalog-management |
| `serviceordermanagement:8080` | cxo-service-order-management |
| `serviceinventorymanagement:8080` | cxo-service-inventory-management |
| `geographicsitemanagement:8080` | cxo-geographic-site-management |
| `geographicaddressmanagement:8080` | cxo-geographic-address-management |
| `geographiclocationmanagement:8080` | cxo-geographic-location-management |
| `resourceinventorymanagement:8080` | cxo-resource-inventory-management |
| `resourcecatalogmanagement:8080` | cxo-resource-catalog-management |
| `resourceordermanagement:8080` | cxo-resource-order-management |
| `resourcepoolmanagement:8080` | cxo-resource-pool-management |
| `eventmanagement:8080` | cxo-event-management |
| `tmfapigateway:8080` | cxo-tmf-api-gateway |
| `serviceorderingengine:8080` | cxo-service-ordering-engine |
| `resourceorderingengine:8080` | cxo-resource-ordering-engine |
| `lockingmanagement:8080` | cxo-locking-management |
| `serviceactivationmanagement:8080` | cxo-service-activation-management |
| `cxosettings:8080` | cxo-settings |
| `audit:8080` | cxo-audit |

All services expose metrics at `/metrics` via `OpenTelemetry.Exporter.Prometheus.AspNetCore` (`MapPrometheusScrapingEndpoint()`).

## Kafka Metrics

Kafka is monitored through `kafka-exporter` (in `docker-compose.kafka.yml`), which talks the plain
Kafka protocol and exposes broker, topic/partition offset and consumer-group lag metrics on
`:9308`. The OTel Collector scrapes it (`cxo-kafka` job) like every other target, so the metrics
carry the usual `cxo_instance` / `environment` labels. Dashboard: **CxO Kafka** (`/d/cxo-kafka`),
also summarised in the Kafka row on CxO Home.

The exporter does not expose broker-internal JMX metrics (request rates and latency per request
type, ISR shrink/expand, request-handler idle, byte throughput). Those need a JMX exporter against
the broker's JMX port 9997, which is not deployed. If you add one, note that `KAFKA_JMX_OPTS`
advertises `-Djava.rmi.server.hostname=kafka0`, which does not resolve on `cxo_network`; it needs
to be `cxo-kafka`.

Conduktor Console (Kafka UI on 8086) has its own monitoring feature, which needs the separate
`conduktor-console-cortex` image. It is not used here: it would run a second Prometheus and
Alertmanager whose data is only visible inside Console.

## Grafana Configuration

### Datasources

| Name | UID | Type | URL |
|------|-----|------|-----|
| Prometheus | `prometheus` | prometheus | `http://cxo-prometheus:9090` |
| Loki | `loki` | loki | `http://cxo-loki:3100` |
| Tempo | `tempo` | tempo | `http://cxo-tempo:3200` |

Loki is configured with a derived field that links `traceId` values to Tempo for trace correlation. Tempo has service-map integration with Prometheus and traces-to-logs linking with Loki.

### Provisioned Dashboards (13)

Provisioned from `files/monitoring/grafana/dashboards/` with `foldersFromFilesStructure`:
**CxO Home** (`cxo-home.json`, dashboards root — the Grafana default home), **Platform
Overview** (Platform Health, Order Flow, CxO Logs, CxO Events), **Components** (TMF APIs,
Engines, Portals, Infrastructure, Postgres, External Dependencies, Kafka), and **CxO Alerts**
(Alerts Overview). See `files/monitoring/grafana/dashboards/README.md` for the authoring
conventions (environment/cxo_instance variables, links, validation).

### Alerting

Alerting rules are provisioned from `files/monitoring/grafana/provisioning/alerting/rules.yml`. No contact point is provisioned: add one in Grafana (**Alerting → Contact points**) or in a provisioning file of your own to be notified.

## Volume Mounts

| Service | Named Volume | Container Path | Content |
|---------|-------------|----------------|---------|
| Prometheus | `prometheusdata` | `/prometheus` | TSDB data |
| Grafana | `grafanadata` | `/var/lib/grafana` | Grafana state, SQLite DB |
| Loki | `lokidata` | `/loki` | Chunks, rules, compactor data |
| Tempo | `tempodata` | `/var/tempo` | WAL and trace blocks |
