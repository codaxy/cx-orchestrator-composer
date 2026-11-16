# Quick start

This brings up the full stack on one machine and signs you in to the Admin Portal.

## Before you start

- **Docker** with Compose v2: Docker Desktop on Windows or macOS, or Docker Engine with the
  compose plugin on Linux.
- **8 GB of memory and several CPUs** for Docker. The full stack runs about 40 containers.
- **Tens of GB of free disk** for images and volumes.
- **A bash shell** for the `.sh` scripts. On Windows use Git Bash or WSL; `.bat` versions of
  `setup`, `startup` and `stop` also exist.
- **Administrator or sudo rights, once**, to add a hosts-file entry.
- **Access to the CxO images.** They are not public. Registry credentials come with your
  agreement with Codaxy, or use a registry that already mirrors them (see
  [Configuration](configuration.md#using-your-own-registry)).

## 1. Sign in to the registry

```bash
docker login ghcr.io -u <user>
```

Use a token that can read packages (for GitHub, a classic personal access token with the
`read:packages` scope). Without it the first `startup` stops with `denied` or `unauthorized`
before anything starts.

## 2. Add the hosts entry

```bash
sudo ./setup.sh          # Windows, as Administrator: setup.bat
```

This adds `local.keycloak.codaxy-cxo` and `local.codaxy-cxo` → `127.0.0.1` to the hosts file.
The portals send your browser to Keycloak under that name, so sign-in fails without it.

## 3. Generate the portal certificate

```bash
./startup.sh gencert
```

This writes a self-signed certificate to `certs/aspnetapp.pfx`, which the three portals serve
HTTPS with. If you have the .NET SDK, `./startup.sh gencert-dotnet` makes a development
certificate your machine already trusts instead.

## 4. Start the stack

```bash
./startup.sh all
```

The first run pulls every image, which takes a while. Containers then start in dependency order:
databases, Kafka and Keycloak first, services after them. Allow a few more minutes after the
command returns, then check:

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | sort
```

Everything should read `Up`, most of them `(healthy)`. A container that keeps restarting is
covered in [Troubleshooting](troubleshooting.md).

## 5. Sign in

Open **https://localhost:40300** (Admin Portal). The browser warns about the self-signed
certificate; accept it. Sign in as **`test` / `test`**, a user with full access to every portal
and the TMF APIs.

Other places to look:

| What | Address |
|---|---|
| Engineering Portal | https://localhost:40302 |
| Resource Manager | https://localhost:40304 |
| TMF API gateway | http://localhost:40600 |
| A service's Swagger, e.g. Service Catalog | http://localhost:40633/swagger |
| Keycloak admin console | http://localhost:8080 (`admin` / `admin`) |
| Logs, metrics, traces (Grafana) | http://localhost:43000 (`admin` / `admin`) |

The full list is in [What runs](what-runs.md#ports).

## 6. Stop it

```bash
./stop.sh
```

Containers are removed; data stays in Docker volumes, and the next `./startup.sh all` picks it
up again.

## Next

- Start only part of the stack, add monitoring or switch engines: [What runs](what-runs.md).
- Pin a release instead of `latest`: [Configuration](configuration.md#pinning-versions).
