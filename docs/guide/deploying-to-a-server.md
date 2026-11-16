# Running on a shared host

The defaults assume one person on one machine: the browser and every container reach Keycloak as
`local.keycloak.codaxy-cxo`, which only that machine's hosts file resolves. To let other people use
the stack, give it a real host name, replace the public placeholder credentials and limit what is
reachable.

All changes below go in your own override directory, as set up in
[Configuration](configuration.md#overriding-settings-and-containers). The examples use
`cxo.example.com` for the host; replace it with yours.

## 1. Give Keycloak a host name

A user's browser and the services must reach Keycloak under the **same** URL: the portals send
the browser there to sign in, and check that the tokens it brings back were issued under that
name.

Create a DNS record for `cxo.example.com` pointing at the host. Then, in
`docker-compose.site.yml`, give the Keycloak container that name inside the stack, and mount the
new address into the three portals and the gateway:

```yaml
services:
  keycloak:
    networks:
      cxo_network:
        aliases:
          - local.keycloak.codaxy-cxo
          - cxo.example.com

  adminportal:
    secrets:
      - source: site-oidc-portal
        target: /app/appsettings-mounted/1/appsettings.json
  engineeringportal:
    secrets:
      - source: site-oidc-portal
        target: /app/appsettings-mounted/1/appsettings.json
  resourcemanager:
    secrets:
      - source: site-oidc-portal
        target: /app/appsettings-mounted/1/appsettings.json
  tmfapigateway:
    secrets:
      - source: site-oidc-gateway
        target: /app/appsettings-mounted/1/appsettings.json

secrets:
  site-oidc-portal:
    file: ../cxo-site/appsettings.OidcPortal.json
  site-oidc-gateway:
    file: ../cxo-site/appsettings.OidcGateway.json
```

`appsettings.OidcPortal.json`:

```json
{
  "OidcConfig": {
    "Authority": "http://cxo.example.com:8080/realms/Codaxy",
    "Issuer": "http://cxo.example.com:8080/realms/master"
  }
}
```

`appsettings.OidcGateway.json`:

```json
{
  "OidcConfig": {
    "Authority": "http://cxo.example.com:8080/realms/Codaxy",
    "Issuer": "http://cxo.example.com:8080/realms/Codaxy"
  }
}
```

Keycloak's published port and its port inside the stack are both 8080, so one URL works from
browsers and containers. The realm's portal clients accept any redirect address, so Keycloak needs
no change for the new name. Users no longer need the hosts-file entry.

The portals are then at `https://cxo.example.com:40300`, `:40302` and `:40304`.

### HTTP and Keycloak

The bundled Keycloak serves plain HTTP. The `Codaxy` realm accepts plain HTTP only from private
addresses (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and localhost); anyone else gets a
page saying **"HTTPS required"**. So this setup serves users on a private network or VPN that
uses those ranges.

For users anywhere else, or any environment that matters, use a Keycloak served over HTTPS that
you operate. Import `data/keycloak/codaxy.json` into it, point `Authority` and `Issuer` at it in
the files above, and remove the bundled one from use. The bundled Keycloak also runs in
development mode with an embedded database, which is not meant for production.

## 2. Use a certificate for your host name

The generated certificate is self-signed and names no host, so every browser warns. Replace
`certs/aspnetapp.pfx` with a PKCS#12 file for `cxo.example.com`.

The portals open it with the password `password`. If yours has another one, set it for the three
portals in `docker-compose.site.yml`:

```yaml
services:
  adminportal:
    environment:
      - ASPNETCORE_Kestrel__Certificates__Default__Password=<pfx password>
  # the same for engineeringportal and resourcemanager
```

The Admin Portal also uses that certificate to encrypt its sign-in keys. Add the password to its
settings fragment as well:

```json
{
  "DataProtectionKeyStore": { "Encryption": { "Password": "<pfx password>" } }
}
```

## 3. Replace the placeholder credentials

Every default password and client secret is published with this repository.

**In Keycloak** (admin console, realm `Codaxy`):

- Change the `admin` password (realm `master`) at first sign-in. The `KC_BOOTSTRAP_ADMIN_*`
  values only apply when Keycloak starts for the first time.
- Delete the `test` user, or set it a real password. Create your users and add them to the
  `cxo-*` groups that match the access they need.
- Under **Clients**, regenerate the secret of `cxo-admin`, `cxo-engineering-portal` and
  `cxo-resource-manager`, and put each in the matching portal's settings fragment:

  ```json
  { "OidcConfig": { "ClientSecret": "<new secret>" } }
  ```

  The three portals then need separate fragment files, since their secrets differ.
- `ext-som`, `ext-rim-ro` and `ext-ro` are example clients for external systems, with example
  secrets. Delete them, or regenerate their secrets before use.

**Elsewhere**, in `docker-compose.site.yml`:

```yaml
services:
  grafana:
    environment:
      GF_SECURITY_ADMIN_PASSWORD: <password>
  pgadmin:
    environment:
      PGADMIN_DEFAULT_PASSWORD: <password>
```

As with Keycloak, the pgAdmin and Grafana values only take effect on a fresh volume; change them in
the application if it has already run.

The PostgreSQL password appears in every service's connection string. Rather than change it,
keep the database unreachable from outside, as below.

## Restrict what is reachable

Every port is published on all interfaces, and Docker publishes them past host firewalls such as
`ufw`. Filter in front of the host (a network firewall or cloud security group), or re-publish
ports on the loopback interface only in `docker-compose.site.yml`:

```yaml
services:
  db:
    ports: !override
      - "127.0.0.1:40100:5432"
```

`!override` needs Docker Compose 2.24.4 or later.

What users need is the three portals (40300, 40302, 40304), Keycloak (8080) and, for systems
calling the TMF APIs, the gateway (40600). Everything else — the individual services, the
databases, Kafka, Redis, Portainer and the monitoring stack — can stay internal and be reached over
SSH tunnels by whoever operates the host.

## Checklist

- [ ] DNS name resolves to the host; Keycloak alias and OIDC files point at it.
- [ ] Users reach Keycloak from a private address, or Keycloak is served over HTTPS.
- [ ] Certificate for the host name in `certs/`.
- [ ] Keycloak admin password changed; `test` user removed; client secrets regenerated.
- [ ] Grafana and pgAdmin passwords changed.
- [ ] Only the portals, Keycloak and the gateway reachable from outside.
- [ ] Image tags pinned in `.env` ([Configuration](configuration.md#pinning-versions)).
- [ ] Log retention set ([Operations](operations.md#disk-space)).
