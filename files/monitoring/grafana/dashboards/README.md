# CxO Grafana dashboards — authoring convention

Dashboards in this tree are provisioned into Grafana by the monitoring stack
(`docker-compose.monitoring.yml` mounts this directory; Kubernetes deployments
can load them via ConfigMaps). They're queried against Prometheus, Loki, and
Tempo data sources defined in `files/monitoring/grafana/provisioning/datasources/`.

## Folder layout

| Folder | What goes here |
|--------|----------------|
| *(root)* | `cxo-home.json` — the landing dashboard (instance/environment selection, per-section summaries with More-details links). |
| `Platform Overview/` | Cross-service summaries: Platform Health, Order Flow, CxO Logs (logging entry point), CxO Events (structured business events). |
| `Components/` | Per-component-group dashboards (TMF APIs, engines, portals, infrastructure, postgres, external dependencies, audit). |
| `CxO Alerts/` | Alert state views. |

`cxo-home.json` is provisioned as the org default home dashboard via
`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH` in `docker-compose.monitoring.yml`
(other deployments set the same `default_home_dashboard_path` ini key).
Operators land there, pick **Environment + CxO Instance** once, and every
link below carries the selection.

A new dashboard goes in the folder that matches its scope. Filename is the
dashboard UID + `.json` (lowercase, hyphenated).

## How this is enforced — honest answer

**Manual convention. No CI.** This repo currently has no GitHub Actions
workflows, no pre-commit hooks, no npm scripts. The rules below are
enforced by **PR review** alone.

A future ticket could add a small `.github/workflows/validate-dashboards.yml`
that runs the verification snippet in the Reviewer checklist on every PR
and fails the check if a dashboard is missing the variable or has
unfiltered queries. That's not done in this PR — the existing 12 dashboards
are 100% covered and new dashboards are rare, so reviewer enforcement is
considered sufficient for now.

If you spot a dashboard PR that drifts, raise it. If drift becomes a
recurring problem, the validator script in the Reviewer checklist below
is small enough to lift into CI in ~20 lines of YAML.

## Mandatory: every dashboard must be multi-instance and multi-environment aware

CxO monitoring is designed to support multiple CxO instances, across
environments, pushing to one Grafana. Every dashboard MUST let the operator scope panels to a single
environment + instance.

### 1. Include the `environment` and `cxo_instance` template variables

Copy verbatim from `Platform Overview/platform-health.json` (the canonical
example). The two blocks live at the top of `templating.list` —
`environment` first, then `cxo_instance` chained to it:

```json
{
  "current": {},
  "datasource": { "type": "prometheus", "uid": "prometheus" },
  "definition": "label_values(up, environment)",
  "hide": 0,
  "includeAll": false,
  "label": "Environment",
  "multi": false,
  "name": "environment",
  "options": [],
  "query": {
    "qryType": 1,
    "query": "label_values(up, environment)",
    "refId": "PrometheusVariableQueryEditor-VariableQuery"
  },
  "refresh": 1,
  "regex": "",
  "skipUrlSync": false,
  "sort": 1,
  "type": "query"
},
{
  "current": {},
  "datasource": { "type": "prometheus", "uid": "prometheus" },
  "definition": "label_values(up{environment=~\"$environment\"}, cxo_instance)",
  "hide": 0,
  "includeAll": false,
  "label": "CxO Instance",
  "multi": false,
  "name": "cxo_instance",
  "options": [],
  "query": {
    "qryType": 1,
    "query": "label_values(up{environment=~\"$environment\"}, cxo_instance)",
    "refId": "PrometheusVariableQueryEditor-VariableQuery"
  },
  "refresh": 1,
  "regex": "",
  "skipUrlSync": false,
  "sort": 1,
  "type": "query"
}
```

Conventions to preserve:
- `includeAll: false` — aggregated "All" hides per-instance differences (sum across
  instances hides which contributes; max-up hides per-instance downtime). Operator
  always sees one instance at a time. Cross-instance comparison is a separate
  Fleet Overview dashboard concern.
- `multi: false` — single-select.
- `current: {}` — Grafana picks the first available value at load.
- `environment` goes first in `templating.list`, `cxo_instance` second, so
  they appear leftmost in the Grafana toolbar in that order. Chaining
  `cxo_instance` to `$environment` means the instance dropdown only offers
  instances that exist in the selected environment.
- Any further query variables (`service`, `db_role`, `dependency`, ...) must
  also be scoped: `label_values(up{environment=~"$environment", cxo_instance=~"$cxo_instance"}, service)`.

### 2. Filter every panel query

Add `environment=~"$environment", cxo_instance=~"$cxo_instance"` as the first
matchers inside the `{ ... }` of every Prometheus query, and as pipe filters
in every Loki query, in `panels[].targets[].expr`.

PromQL examples:

```promql
# rate / sum / histogram_quantile — inside the {} of the selected metric
sum(rate(http_server_request_duration_seconds_count{environment=~"$environment", cxo_instance=~"$cxo_instance", service="$service"}[5m]))

# stat panel — same pattern
max(up{environment=~"$environment", cxo_instance=~"$cxo_instance", service="cxo-party-management"})

# bare metric with range vector — add a label selector
sum(rate(cxo_orders_received_total{environment=~"$environment", cxo_instance=~"$cxo_instance"}[5m])) by (domain)
```

LogQL example (Loki):

```logql
{service_name="$service"} | environment=~"$environment" | cxo_instance=~"$cxo_instance" | detected_level=~"warn|error|fatal"
```

### 3. Dashboard links must carry the selection

Every dashboard's top-level `links` array contains exactly one entry: the
`All dashboards` dropdown (`"type": "dashboards"`, `"tags": ["cxo"]`) with
`"includeVars": true` and `"keepTime": true`. This is what makes the
environment/instance selection survive navigation between dashboards.
In-dashboard navigation (e.g. Home's "More details…" tiles) uses panel
text links that append `var-environment=$environment&var-cxo_instance=$cxo_instance`.
Grafana OSS does not persist variable selections server-side between visits —
the selection lives in the URL (`var-environment=...&var-cxo_instance=...`),
so entry always goes through the Home dashboard (default landing page) or a
bookmarked URL.

**Important LogQL detail**: in our Loki deployment only `service_name` is an
*indexed stream label* (the thing that goes inside `{...}`). Every other
attribute — `cxo_instance`, `environment`, `trace_id`, `OrderId`, etc. — is
*structured metadata* and must be filtered with a `|` pipe **after** the
stream selector. Putting `cxo_instance` inside `{...}` returns zero results
on a deployed Loki because Loki doesn't recognise it as a stream label.
Verify with `curl http://<loki>/loki/api/v1/labels` — if the response lists
only `service_name`, every other filter must use the pipe form.

PromQL is different — Prometheus treats all labels uniformly, so
`cxo_instance` goes inside `{...}` like any other label matcher.

Why `=~` rather than `=`: `=~` is a regex match — works with a single literal
value (`local` matches `local`) and with future regex shapes if the variable
ever becomes a comma-separated multi-select.

### 4. Where the labels come from

The `cxo_instance` and `environment` labels are attached by the OTel
Collector's `resource` processor (see `files/monitoring/otel-collector/config.yml`).
The values are sourced from the `CXO_INSTANCE_NAME` / `CXO_ENVIRONMENT` env
vars on the collector, which are wired up in `docker-compose.monitoring.yml`
(both default `local`) and overridden per deployment.

A dashboard query that forgets these filters still works in single-instance
mode (one value to match) but silently breaks once a second instance or
environment arrives — it would mix series from all of them into one panel.

## Verifying a new dashboard

After authoring or editing, before opening the PR:

```bash
# Validate JSON parses
node -e "JSON.parse(require('fs').readFileSync('files/monitoring/grafana/dashboards/<folder>/<file>.json'))"

# Grep for the variable presence
grep -l '"name": "cxo_instance"' files/monitoring/grafana/dashboards/<folder>/<file>.json

# Grep for queries that forgot the filter (should return empty)
grep -E '"expr":\s*"[^"]*\{[^"]*\}' files/monitoring/grafana/dashboards/<folder>/<file>.json \
  | grep -v 'cxo_instance'
```

After deploying (local Docker or a shared environment):

```bash
# Hard-refresh Grafana so it re-reads provisioning
docker restart cxo-grafana
```

Then open the dashboard in Grafana, confirm the `CxO Instance` dropdown
appears, switch values, confirm panels redraw.

## Reviewer checklist

When reviewing a PR that adds or modifies a dashboard, verify by hand:

- [ ] The `environment` and `cxo_instance` template variables are present and match the canonical shape above.
- [ ] Every `expr` field includes `environment=~"$environment"` and `cxo_instance=~"$cxo_instance"` (or more specific filters).
- [ ] Variables appear first in `templating.list` (`environment`, then `cxo_instance`).
- [ ] Every dashboard link sets `includeVars: true` and `keepTime: true` (the single `All dashboards` dropdown — see rule 3).
- [ ] JSON parses (no trailing comma, no syntax error).

Or run this one-liner from the repo root — **empty output means all
dashboards comply**:

```bash
node -e 'const fs=require("fs"),path=require("path");function w(d,o=[]){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);e.isDirectory()?w(p,o):e.name.endsWith(".json")&&o.push(p)}return o}for(const f of w("files/monitoring/grafana/dashboards")){let d;try{d=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){console.log("INVALID JSON:",f,e.message);continue}for(const name of ["cxo_instance","environment"])if(!(d.templating?.list||[]).some(v=>v?.name===name))console.log("MISSING VAR "+name+":",f);let e1=0,fi=0,fe=0;(function w(o){if(!o||typeof o!=="object")return;if(Array.isArray(o)){o.forEach(w);return}if(typeof o.expr==="string"){e1++;if(o.expr.includes("cxo_instance"))fi++;if(o.expr.includes("$environment"))fe++}for(const k of Object.keys(o))w(o[k])})(d.panels||[]);if(e1!==fi)console.log("UNFILTERED instance:",path.basename(f),fi+"/"+e1);if(e1!==fe)console.log("UNFILTERED environment:",path.basename(f),fe+"/"+e1);for(const l of d.links||[])if(l.type==="link"&&(!l.includeVars||!l.keepTime))console.log("LINK not carrying vars:",path.basename(f),l.title)}'
```

If that ever needs to become a CI check, lift it into
`.github/workflows/validate-dashboards.yml` — same script, same exit
codes (non-empty output ⇒ fail).
