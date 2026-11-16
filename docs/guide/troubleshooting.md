# Troubleshooting

Start with the state of the containers and the log of the one that fails:

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | sort
docker logs --tail 100 <container>
```

## Starting

**`denied` or `unauthorized` when pulling a `cxo-*` image.** The registry login is missing or
cannot read packages. Run `docker login` with a token that has read access to packages
([Quick start](quick-start.md#1-sign-in-to-the-registry)). One failed pull stops the whole start.

**`Error: certs/aspnetapp.pfx not found`.** Run `./startup.sh gencert` once.

**`port is already allocated` / `address already in use`.** Another program uses one of the
stack's ports, often 8080 or 9090. Stop it, or re-publish that port in your override
([Running on a shared host](deploying-to-a-server.md#restrict-what-is-reachable)).

If nothing listens on the port (`ss -ltn` does not show it), an outgoing connection holds it.
Linux gives outgoing connections local ports from 32768–60999, and most of the stack's ports
are in that range. Check with `ss -tan | grep ':<port> '`. Retry once the connection has
closed. To stop it happening, reserve the stack's ports (Linux):

```bash
sudo sysctl -w net.ipv4.ip_local_reserved_ports=40100-40720,43000,45000,48081,49000,50211-50640,63790
echo 'net.ipv4.ip_local_reserved_ports=40100-40720,43000,45000,48081,49000,50211-50640,63790' \
  | sudo tee /etc/sysctl.d/90-cxo-ports.conf
```

The reservation applies to new connections; one that already holds a port keeps it.

**A container is running but cannot be reached, or cannot reach anything.** It was created
during a start that failed, often on a port, and later starts reuse it without its network.
`docker inspect <container> --format '{{json .NetworkSettings.Networks}}'` prints `{}`.
Recreate it: `docker compose ... up -d --force-recreate --no-deps <service>`.

**Windows: `bind: An attempt was made to access a socket in a way forbidden by its access
permissions`.** Windows has reserved the port. As Administrator, run `net stop hns` and
`net start hns`, then start again.

**A container keeps restarting.** Usually something it depends on is not ready yet: on first
start Keycloak imports its realm and Kafka elects a controller, which takes a minute or two.
Give it a few minutes; `restart: unless-stopped` retries on its own. If it continues, its log
names what it cannot reach.

**`Pool overlaps with other one on this address space` with `--with-pgbouncer`.** The PgBouncer
setup uses the fixed subnet `10.100.200.0/24`, and another Docker network on the host already
uses it. Remove that network or stop the stack that owns it.

**Services cannot connect to the database after adding `--with-pgbouncer`.** The database
volume was created without it. Run `scripts/postgres/migrate-to-pgbouncer.sh`
([What runs](what-runs.md#pgbouncer)).

**Two stacks on one host overwrite each other's containers.** Give each its own
`CONTAINER_PREFIX` and `COMPOSE_PROJECT_NAME` in `.env`. Host ports still have to differ.

## Signing in

**The browser cannot open `local.keycloak.codaxy-cxo`.** The hosts entry is missing on the
machine running the browser. Run `sudo ./setup.sh` (Windows: `setup.bat` as Administrator), or
give the stack a real host name ([Running on a shared host](deploying-to-a-server.md)).

**Keycloak shows "HTTPS required".** The browser reaches Keycloak from an address outside the
private ranges, and the realm accepts plain HTTP only from those. Serve Keycloak over HTTPS
([Running on a shared host](deploying-to-a-server.md#http-and-keycloak)). On a machine only you
use, you can instead set **Realm settings → General → Require SSL → None** in the `Codaxy`
realm. Never do that on a host others can reach.

**The browser warns about the certificate** (`NET::ERR_CERT_AUTHORITY_INVALID`,
`ERR_CERT_COMMON_NAME_INVALID`). The generated certificate is self-signed and names no host.
Accept it, use `./startup.sh gencert-dotnet` for one your machine trusts, or install a
certificate for your host name.

**Sign-in loops back, or the portal reports an invalid token or issuer.** The portal and the
browser reach Keycloak under different names. `Authority` and `Issuer` must use exactly the
name, scheme and port the browser uses, and Keycloak must carry that name as a network alias.

## Running

**A setting change has no effect.** A container does not notice a changed settings file.
Recreate it: `docker compose ... up -d --force-recreate --no-deps <service>`. If you set it as
an environment variable, set it in a mounted settings file instead
([Configuration](configuration.md#how-a-service-reads-its-settings)).

**Workflows are missing after switching between Conductor and CxMaestro.** Services register
their definitions when they start. Restart them: `docker compose -f docker-compose.yml restart`.

**The disk fills up.** See [Operations](operations.md#disk-space).
