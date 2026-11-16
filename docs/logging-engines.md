# CxO Engine Logging Guidelines

Logging patterns and conventions for the 5 ConductorSharp-based engine services.

**Applies to:** cxo-service-ordering-engine, cxo-resource-ordering-engine.

> **Since CxO.Observability 0.7** the sink/enricher mechanics are provided by the shared
> bootstrap (`AddCxoObservability`), exactly as for the TMF services — see
> [logging-tmf-services.md](logging-tmf-services.md) for the shared contract. This page covers
> what is *engine-specific*: the ConductorSharp MediatR pipeline behaviors and cross-service
> header propagation.

## Serilog Configuration

The bootstrap configures Serilog with the platform defaults: Information minimum (`Microsoft`
at Warning), `FromLogContext` + machine/process/thread/span enrichment (trace and span ids
come from the bundled span enricher reading `Activity.Current`), a Console sink, an OTLP sink
shipping to the OTel Collector (and from there to Loki) with `service.name` from the
`AddCxoObservability` argument, and 8192-char caps on string log properties.

The deployment overlay (`settings/local/appsettings.<Engine>.json`) only adds
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

> The direct `GrafanaLoki` sink from the pre-0.7 convention is **retired**: logs reach Loki via
> the OTel Collector, which stamps the `cxo_instance` / `environment` deployment attributes the
> Grafana dashboards filter on. In Loki, streams are selected by `service_name` (from the
> bootstrap argument), not by an `Application` label.

Engines additionally emit **structured business events** out of the box: the ordering engines
log `OrderExecutionStarted` / `CancelOrderExecutionStarted` / `LingeringOrderSwept` per
dispatched order, and the worker-based engines log `WorkflowTaskExecuted` per Conductor task
run via a `CxoEventBehavior` in the MediatR pipeline — see the CxO Events dashboard.

## Standard Structured Properties

Every log line from an engine should include these properties:

| Property | Source | Example |
|----------|--------|---------|
| `TraceId` | span enricher (bundled with CxO.Observability) from `Activity.Current` | `a1b2c3d4e5f6...` |
| `SpanId` | span enricher (bundled with CxO.Observability) from `Activity.Current` | `1234abcd...` |
| `UserId` | `CallerIdentityHandler` sets `X-User-Id` on outgoing calls | `svc:cxo-service-ordering-engine` |
| `OrderId` | `OrderIdLoggingBehavior` + `ContextPropagationBehavior` | `f8e1347c-cc44-...` |
| `WorkflowId` | `ContextPropagationBehavior` from `ConductorSharpExecutionContext` | `1773874b-5cf0-...` |
| `CorrelationId` | `ContextPropagationBehavior` from `ConductorSharpExecutionContext` | `n/a` (or GUID if set) |
| `ConductorContext` | `ContextLoggingBehavior` (built-in, serialized object) | `{WorkflowId, TaskId, ...}` |

## MediatR Pipeline Behaviors

Engines use ConductorSharp's MediatR pipeline. Behaviors execute in registration order for each task handler invocation.

### ContextLoggingBehavior (built-in, from ConductorSharp.Engine)

Pushes the full `ConductorSharpExecutionContext` as a serialized `ConductorContext` property. This is a nested object containing `WorkflowId`, `TaskId`, `WorkflowName`, etc.

```csharp
// ConductorSharp.Engine.Behaviors.ContextLoggingBehavior
using var _ = LogContext.PushProperty("ConductorContext", _executionContext, true);
return await next();
```

### OrderIdLoggingBehavior

Extracts `OrderId` from the MediatR request via cached reflection (`Lazy<T>`) and pushes it to `LogContext`. Only activates when the request type has an `OrderId` property.

```csharp
var orderId = OrderIdAccessor.Value?.Invoke(request);
if (orderId is not null)
{
    using (LogContext.PushProperty("OrderId", orderId))
        return await next();
}
return await next();
```

### ContextPropagationBehavior

Serves two purposes:
1. Pushes `WorkflowId` and `CorrelationId` as flat top-level Serilog properties (flattening them from the nested `ConductorContext`)
2. Populates `CxoPropagationContext` so that `CallerIdentityHandler` can forward them as HTTP headers

```csharp
CxoPropagationContext.WorkflowId = executionContext.WorkflowId;
CxoPropagationContext.CorrelationId = executionContext.CorrelationId;
CxoPropagationContext.OrderId = OrderIdAccessor.Value?.Invoke(request)?.ToString();

using (LogContext.PushProperty("WorkflowId", executionContext.WorkflowId ?? "n/a"))
using (LogContext.PushProperty("CorrelationId", executionContext.CorrelationId ?? "n/a"))
{
    try { return await next(); }
    finally { CxoPropagationContext.Clear(); }
}
```

**Registration** in `ServiceCollectionExtensions.cs`:

```csharp
.AddPipelines(pipelines =>
{
    pipelines.AddExecutionTaskTracking();
    pipelines.AddContextLogging();
    pipelines.AddRequestResponseLogging();
    pipelines.AddValidation();
    pipelines.AddCustomBehavior(typeof(OrderIdLoggingBehavior<,>));
    pipelines.AddCustomBehavior(typeof(ContextPropagationBehavior<,>));
})
```

## Cross-Service Header Propagation

### CxoPropagationContext

An `AsyncLocal`-based static class that bridges the MediatR pipeline (where Conductor context is available) to the `HttpClient` DelegatingHandler (which runs in a different scope).

**Location:** `Handlers/CxoPropagationContext.cs` in each engine's Web/Api project.

Properties: `OrderId`, `WorkflowId`, `CorrelationId` -- set by `ContextPropagationBehavior`, read by `CallerIdentityHandler`, cleared in a `finally` block.

### CallerIdentityHandler

A `DelegatingHandler` registered on all outgoing `HttpClient` instances. Adds context headers to every HTTP request the engine makes to TMF services:

| Header | Value Source |
|--------|-------------|
| `X-User-Id` | `svc:{service-name}` (e.g., `svc:cxo-service-ordering-engine`) |
| `X-Order-Id` | `CxoPropagationContext.OrderId` |
| `X-Workflow-Id` | `CxoPropagationContext.WorkflowId` |
| `X-Correlation-Id` | `CxoPropagationContext.CorrelationId` |

Headers are only added when the value is non-null.

## Conventions

- Use structured logging with message templates: `_logger.LogInformation("Order {OrderId} state: {State}", id, state)` -- never string interpolation.
- Rely on the pipeline behaviors for ambient context -- do not manually push `WorkflowId` or `OrderId` in task handlers.
- When adding a new property to outgoing HTTP calls, add it to both `CxoPropagationContext` and `CallerIdentityHandler`.
- Never log whole request/response payloads as properties -- log IDs, types, and sizes. Since 0.7.3 the bootstrap truncates string properties over 8192 chars as a safety net, but the lean log line is the convention.
- The service name passed to `AddCxoObservability` must match the `service` label in the collector's scrape config so metric and log identities line up on dashboards.
