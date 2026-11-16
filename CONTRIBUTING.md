# Contributing to cx-orchestrator-composer

cx-orchestrator-composer is the reference way to deploy a CxO stack — locally, in test
environments, and as a starting point for production deployments. It is public,
so everything in it must be safe for anyone to read. That constraint drives
the two rules below.

## Rule 1 — Which services belong here

**Only product services.** A service belongs in cx-orchestrator-composer if a client
implementation would (or could) deploy it: TMF API services, workflow engines,
portals, the API gateway, and the infrastructure they need (PostgreSQL,
Kafka, Conductor, Keycloak, Redis, monitoring, logging).

**Demo services do not belong here.** Anything that exists to demo CxO —
demo portals, demo engines, sample workflow implementations, and
infrastructure used only by them — lives outside this repository, in the
configuration of the environments that use it.

Rules of thumb when adding a service:

- If the service's repo/image name carries the `cxo-demo-` prefix, it goes to
  that environment's configuration. If a service is demo-only but *not* named
  `cxo-demo-*`, rename the repo/image first.
- Environment-specific configuration (hostnames, environment-only tooling,
  integrations with one installation) also stays out of this repository.
- A demo service's footprint is more than its compose entry. When moving or
  adding one, account for: appsettings, database creation scripts, PgBouncer
  pool entries, Keycloak clients/roles/groups in `data/keycloak/codaxy.json`,
  OTel collector scrape targets, Grafana dashboards, and README/docs tables.

## Rule 2 — How to handle secrets

**Every secret committed to this repository is public.** Treat the git
history as world-readable: externals may get access to the repo, and history
rewrites are expensive and disruptive. Therefore:

- Only *well-known placeholder* secrets are allowed: local development
  passwords (`postgres/postgres`, `admin/admin`), the shared local Keycloak
  client secrets in `settings/local/`, and the self-signed dev certificate.
  These are considered publicly known by design and must never be reused in
  any real environment (test, staging or production).
- **Never commit a real credential** — no environment passwords, API keys,
  tokens, cloud credentials, kubeconfigs, or client-specific values. Not even
  "temporarily". If it identifies or grants access to a real system, it does
  not belong here.
- Environment-specific secrets belong in that environment's own private
  configuration or in gitignored local files (`.env`,
  `docker-compose.override.yml`). The compose files follow a layered
  appsettings pattern for exactly this reason: this repo mounts the public
  defaults at `/app/appsettings-mounted/0/`, and environment overrides mount
  their secrets at `/app/appsettings-mounted/1/` from outside this repo.
- Hostnames, ports, and topology of real environments are also
  best kept out of this repo — use placeholders, and document them where that
  environment is documented.
- If a real secret does land in a commit: rotate it immediately, then remove
  it from the tree. Assume it is compromised the moment it is pushed —
  removing the file does not remove it from history.

When in doubt, ask yourself: *"Would I be comfortable if a client's
implementation team read this line?"* If not, it goes to that environment's own
configuration or stays out of git entirely.
