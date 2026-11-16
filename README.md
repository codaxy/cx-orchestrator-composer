# Cx Orchestrator Composer

Run a complete CxO stack with Docker Compose: the TM Forum Open API services, the ordering and
activation engines, the portals, the API gateway, and their infrastructure (PostgreSQL, Kafka,
Keycloak, Redis, Conductor or CxMaestro, and Grafana with Prometheus, Loki and Tempo).

This repository holds compose files, default settings and scripts. Every CxO component is a
container image.

> **The CxO images are not public.** Pulling `ghcr.io/codaxy/cxo-*` needs registry access from
> Codaxy, or a registry of your own that mirrors the images
> ([Configuration](docs/guide/configuration.md#using-your-own-registry)).

> **The defaults are for one machine.** Every password and client secret here is a public
> placeholder. Before others can reach the stack, follow
> [Running on a shared host](docs/guide/deploying-to-a-server.md).

## Quick start

Docker with Compose v2, 8 GB of memory for Docker, and a bash shell (`.bat` versions exist for
Windows).

```bash
docker login ghcr.io             # with your registry credentials
sudo ./setup.sh                  # hosts entry for local Keycloak (once)
./startup.sh gencert             # portal certificate (once)
./startup.sh all                 # everything, monitoring included
```

Open https://localhost:40300 and sign in as `test` / `test`. Grafana is at http://localhost:43000
(`admin` / `admin`). Stop with `./stop.sh`; data stays in Docker volumes.

## Documentation

| Page | Covers |
|---|---|
| [Quick start](docs/guide/quick-start.md) | The steps above, with what to expect at each. |
| [What runs](docs/guide/what-runs.md) | Startup targets and options, CxMaestro, merged images, PgBouncer, ports, default sign-ins. |
| [Configuration](docs/guide/configuration.md) | `.env`, pinning a release, your own registry, changing settings without editing tracked files. |
| [Running on a shared host](docs/guide/deploying-to-a-server.md) | Host name for sign-in, certificate, credentials, open ports. |
| [Operations](docs/guide/operations.md) | Upgrading, logs, backup and restore, disk space. |
| [Troubleshooting](docs/guide/troubleshooting.md) | Symptoms and fixes. |

Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

The files in this repository are licensed under the [Apache License 2.0](LICENSE); see also
[NOTICE](NOTICE). The CxO container images they deploy are licensed separately by Codaxy. Trial
access is available on request.
