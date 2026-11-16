# Configuration

Keep your changes **outside the tracked files**: in `.env`, and in a compose file and settings
files of your own. Then upgrading is a `git pull` with nothing to merge, and the defaults in the
repository stay the reference you compare against.

## The `.env` file

Compose reads `.env` from the repository root; it is not committed. Start from the sample:

```bash
cp .env.sample .env
```

| Variable | Default | Purpose |
|---|---|---|
| `CXO_TAG` | `latest` | Image tag for every CxO component. |
| `CXO_<SERVICE>_TAG` | `CXO_TAG` | Tag for one component, e.g. `CXO_SERVICE_CATALOG_MANAGEMENT_TAG`. |
| `CXO_MAESTRO_TAG` | `latest` | Tag for CxMaestro. |
| `CXO_IMG_BASE_URL` | `ghcr.io/codaxy` | Registry and path the CxO images are pulled from. |
| `HL_INFRA_IMG_BASE_URL` | each image's public registry | One flat registry path for the infrastructure images. |
| `CXO_ORCHESTRATOR` | `conductor` | `maestro` to run CxMaestro on every start. |
| `CXO_MERGED_IMAGES` | none | `sm,rm,cdm` (or a subset), the same as `--with-merged`. |
| `CONTAINER_PREFIX` | none | Prefix for container and network names. |
| `COMPOSE_PROJECT_NAME` | `cxo-composer` | Compose project name; volume names start with it. Set together with `CONTAINER_PREFIX` to run two stacks on one host. |
| `CXO_TZ` | `Europe/Amsterdam` | Time zone of the orchestration engine and its database. |
| `CXO_INSTANCE_NAME`, `CXO_ENVIRONMENT` | `local` | Labels on every metric, log and trace, offered as filters in Grafana. |
| `CXO_ORCHESTRATOR_DB_DSN` | Conductor's database | Connection the monitoring stack uses for the engine's database. Set it with `CXO_ORCHESTRATOR=maestro`. |

## Pinning versions

`latest` moves whenever a new image is published. For anything other than a quick look, run a
release.

Every CxO release is a tag of both the images and this repository, so the compose files and
default settings you run match the images. Check out the release and set the same tag in `.env`:

```bash
git fetch --tags
git checkout 26q3
```

```bash
CXO_TAG=26q3
```

Releases come in three kinds: quarterly (`26q3`), monthly (`26m11`) and weekly (`26w46`, with
`26w46.1` for a fix within that week). Quarterly releases are the ones meant for most
installations. Tags are lowercase; `git tag -l` lists them.

A single component can differ from the rest, for example to take a fix from a later weekly:

```bash
CXO_TAG=26q3
CXO_RESOURCE_POOL_MANAGEMENT_TAG=26w46
```

## Using your own registry

To pull from a registry you control, copy the images there and point the stack at it:

```bash
CXO_IMG_BASE_URL=registry.example.com/cxo          # → registry.example.com/cxo/cxo-party-management:<tag>
HL_INFRA_IMG_BASE_URL=registry.example.com/cxo/infra  # → registry.example.com/cxo/infra/postgres:15-bookworm
```

`HL_INFRA_IMG_BASE_URL` drops the original namespace: `docker.io/library/postgres` and
`docker.io/grafana/grafana` become `<base>/postgres` and `<base>/grafana`. Keycloak, Conductor and
PgBouncer are Codaxy builds and come from the same base, so mirror them too.

List the images a configuration uses, with your `.env` applied:

```bash
docker compose -f docker-compose.yml config --images | sort -u
docker compose -f docker-compose.monitoring.yml config --images | sort -u   # if you use monitoring
```

CxMaestro (`cx-maestro-alpha`) is only listed when `CXO_ORCHESTRATOR=maestro`.

## How a service reads its settings

Each service reads, in order, its built-in `appsettings.json` and then any of these files that
exist; **a later file overrides an earlier one**:

```
/app/appsettings-mounted/0/appsettings.json          ← settings/local/appsettings.<Service>.json
/app/appsettings-mounted/1/appsettings.json
/app/appsettings-mounted/2/appsettings.json
/app/appsettings-mounted/0-config/appsettings.json
/app/appsettings-mounted/1-secret/appsettings.json
/app/appsettings-mounted/2-extra/appsettings.json
```

The repository fills slot `0`. The others are free for you. A file you mount holds only the keys
you change; everything else still comes from the defaults.

Set service settings this way rather than with environment variables. Depending on the image
version, a mounted file can take precedence over an environment variable of the same key, so a
variable may appear in the container and still be ignored.

## Overriding settings and containers

Put your overrides in a directory next to the clone, for example `../cxo-site/`:

```
cx-orchestrator-composer/ ← this repository, unchanged
cxo-site/
  docker-compose.site.yml
  appsettings.Oidc.json
  up.sh
```

`docker-compose.site.yml` mounts your files into a free slot and changes anything else about a
container. Relative paths are resolved from the repository directory:

```yaml
services:
  adminportal:
    secrets:
      - source: site-oidc
        target: /app/appsettings-mounted/1/appsettings.json

secrets:
  site-oidc:
    file: ../cxo-site/appsettings.Oidc.json
```

`startup.sh` does not take extra compose files, so start the stack with `docker compose`
directly and list the same files it would. For `all` with Conductor, `up.sh`:

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/../cx-orchestrator-composer"
exec docker compose \
  -f docker-compose.yml \
  -f docker-compose.portals.depends.conductor.yml \
  -f docker-compose.services.engines.depends.conductor.yml \
  -f docker-compose.services.util.depends.conductor.yml \
  -f ../cxo-site/docker-compose.site.yml \
  "$@"
```

```bash
../cxo-site/up.sh up -d       # start or apply changes
../cxo-site/up.sh ps
../cxo-site/up.sh down
```

For CxMaestro, replace `conductor` with `maestro` in the three file names and set
`CXO_ORCHESTRATOR=maestro` in `.env`. Add `-f docker-compose.monitoring.yml` for monitoring.

Check the merged result before starting:

```bash
../cxo-site/up.sh config adminportal
```

A changed settings file does not restart a running container by itself. Recreate it:

```bash
../cxo-site/up.sh up -d --force-recreate --no-deps adminportal
```
