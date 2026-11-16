# CxO TMF Service Logging Guidelines

Logging patterns and conventions for the 16 TMF API services.

**Applies to:** cxo-party-management, cxo-digital-identity, cxo-party-role-management, cxo-customer-management, cxo-user-roles-and-permissions, cxo-service-catalog-management, cxo-service-order-management, cxo-service-inventory-management, cxo-geographic-site-management, cxo-geographic-address-management, cxo-geographic-location-management, cxo-resource-inventory-management, cxo-resource-catalog-management, cxo-resource-order-management, cxo-resource-pool-management, cxo-event-management.

> **Since CxO.Observability 0.7** the mechanics in this document are provided by the shared
> bootstrap (`AddCxoObservability` + `UseCxoObservability`) — services no longer hand-write
> Serilog sink config or the request-logging/LogContext middleware. This page documents the
> *behavior and contracts*.

## Serilog Configuration

The bootstrap configures Serilog with the platform defaults: Information minimum (`Microsoft`
at Warning), `FromLogContext` + machine/process/thread/span enrichment, a Console sink, and an
OTLP sink shipping to the OTel Collector (and from there to Loki) with `service.name` taken
from the `AddCxoObservability` argument.

The deployment overlay (`settings/local/appsettings.<Service>.json`) only adds
deployment-specific sinks or level overrides:

```json
{
  "Serilog": {
    "MinimumLevel": {
      "Override": { "System.Net.Http.HttpClient": "Warning" }
    }
  }
}
```

Sinks declared under `WriteTo` are added to the bootstrap's Console and OpenTelemetry sinks;
a declared `Console` or `OpenTelemetry` sink replaces the matching default.

A `Console` or `OpenTelemetry` entry declared in config *suppresses* the matching bootstrap
sink (the deployment declared it, the deployment owns it) — do not re-add them unless you
deliberately want to take the sink over.

> The direct `GrafanaLoki` sink from the pre-0.7 convention is retired: logs reach Loki via
> the OTel Collector, which stamps the `cxo_instance` / `environment` deployment attributes
> that the Grafana dashboards filter on.

Two more library-provided behaviors worth knowing (0.7.2/0.7.3+):

- **Structured business events** — `logger.LogCxoEvent(...)` (namespace
  `CxO.Observability.Logging`) logs dashboard-aggregatable events with a fixed envelope
  (`EventType`, `EntityType`, `EntityId`, `Status`, `DurationMs`, `Reason`); the CxO Events
  dashboard and the Home Business Events row are built entirely on it.
- **Oversized-property caps** — string log properties are truncated at 8192 chars
  (`…[truncated]` suffix; destructured values capped at depth 5 / 100 elements) so one fat
  property can never exceed Loki's 64KB structured-metadata limit and cost the collector a
  whole export batch. Log IDs/types/sizes, never whole objects — the cap is a safety net, not
  a license.

## Standard Structured Properties

Every log line from a TMF service carries these properties (enriched by the bootstrap):

| Property | Source | Default |
|----------|--------|---------|
| `TraceId` / `SpanId` | `Serilog.Enrichers.Span` (bundled) from `Activity.Current` | (current trace) |
| `MachineName` / `ProcessId` / `ThreadId` | bundled enrichers | (host values) |
| `UserId` | JWT claim or `X-User-Id` header | `"anonymous"` |
| `OrderId` | `X-Order-Id` header (or URL path — see below) | `"n/a"` |
| `WorkflowId` | `X-Workflow-Id` header | `"n/a"` |
| `CorrelationId` | `X-Correlation-Id` header | `"n/a"` |
| `ClientIp` | `HttpContext.Connection.RemoteIpAddress` | `"unknown"` |

## Request Logging and LogContext — provided by `UseCxoObservability()`

`app.UseCxoObservability()` wires two pieces (previously duplicated by hand across every
service — see `CxoRequestLoggingConfiguration` and `CxoLogContextMiddleware` in
`CxO.Observability`):

1. **Serilog request logging** — one summary line per HTTP request
   (`HTTP {Method} {Path} responded {StatusCode} in {Elapsed}`), enriched with the properties
   above via `DiagnosticContext`. Probe paths (`/health`, `/ready`, `/live`, `/metrics`) are
   downgraded to `Verbose` so they don't clutter Info logs; requests that throw or return 5xx
   log at `Error`.
2. **LogContext middleware** — pushes the same dimensions onto Serilog's ambient `LogContext`
   (so *every* log line during the request carries them, not just the summary) and stamps them
   as tags on the current `Activity`, unifying log and trace vocabulary.

**Placement:** call `app.UseCxoObservability()` after `app.UseAuthentication()` /
`app.UseAuthorization()` so JWT claims resolve; otherwise `UserId` is `anonymous` for
authenticated requests.

**Why both `DiagnosticContext` and `LogContext`?** `DiagnosticContext` enriches only the
single request-summary line emitted by the request-logging middleware. `LogContext` is an
ambient scope that enriches every log statement during the request's lifetime. The bootstrap
provides both.

## OrderId from URL Path

When the `X-Order-Id` header is absent, the shared middleware extracts `OrderId` from the
request path for direct API calls — it matches the GUID segment in both
`/serviceOrder/{guid}` and `/resourceOrder/{guid}` paths (e.g.
`/tmf-api/serviceOrdering/v4/serviceOrder/f8e1347c-cc44-4c83-b1e7-89e47c64dcae`). This is no
longer SOM-specific code; it ships in `CxoRequestLoggingConfiguration`.

## Header Contract

TMF services read but do not forward these headers. They are set by upstream callers:

| Header | Set By | Purpose |
|--------|--------|---------|
| `X-User-Id` | API Gateway (from JWT), Engine `CallerIdentityHandler`, Portal backends | Identifies the acting user or service |
| `X-Order-Id` | Engine `CallerIdentityHandler` | Links logs to the originating order |
| `X-Workflow-Id` | Engine `CallerIdentityHandler` | Links logs to the Conductor workflow instance |
| `X-Correlation-Id` | API Gateway (generated or forwarded), Engine `CallerIdentityHandler` | End-to-end request correlation |

## Canonical Example

`cxo-party-management` (`src/PartyManagement.Api/Program.cs`) is the canonical reference for
the standard TMF pattern: `builder.AddCxoObservability("cxo-party-management")`,
`app.UseCxoObservability()`, `app.MapCxoObservabilityEndpoints()` — no `UseSerilog`, no
hand-written logging middleware.

## Conventions

- Use structured logging with message templates: `_logger.LogInformation("Created party {PartyId}", id)` — never string interpolation.
- Never manually push `UserId`, `OrderId`, `WorkflowId`, or `CorrelationId` in controllers or services; the shared middleware handles it.
- Default values (`"anonymous"` for UserId, `"n/a"` for others) ensure Loki queries work without null-handling.
- The service name passed to `AddCxoObservability` must match the `service` label in the collector's scrape config (`files/monitoring/otel-collector/config.yml`) so metric and log identities line up on dashboards.
