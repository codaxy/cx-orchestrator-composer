# Cx Orchestrator Composer

Cx Orchestrator Composer runs a complete CxO (Codaxy Orchestrator) stack with Docker Compose: the TM Forum
Open API services, the ordering and activation engines, the portals, the API gateway, and the
infrastructure they need (PostgreSQL, Kafka, Keycloak, Redis, an orchestration engine, logging
and optional monitoring).

It holds no application code. Every CxO component is a container image; this repository holds
the compose files, the default configuration and the scripts that start them.

## What it is for

- **Evaluating CxO** on a workstation.
- **Developing against CxO**: integrations, workflows, catalogs, clients of the TMF APIs.
- **A starting point for a shared environment** (test, staging). The defaults are written for
  one machine and must be changed first; see [Running on a shared host](deploying-to-a-server.md).

It is **not a production deployment as shipped**. Every password and client secret in it is a
public placeholder, Keycloak runs in development mode, and no port is restricted.

## Read in this order

| Page | When |
|---|---|
| [Quick start](quick-start.md) | First run on your machine, about 20 minutes. |
| [What runs](what-runs.md) | Which containers start, the startup targets and options, ports and default sign-ins. |
| [Configuration](configuration.md) | Pinning versions, using your own registry, changing service settings without editing tracked files. |
| [Running on a shared host](deploying-to-a-server.md) | Serving the stack to other people under a host name. |
| [Operations](operations.md) | Upgrading, stopping, logs, backup and restore, resetting. |
| [Troubleshooting](troubleshooting.md) | Symptoms and fixes. |
