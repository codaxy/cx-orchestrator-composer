# Keycloak Seed Scripts

Idempotent scripts for provisioning Keycloak configuration into an existing realm. All scripts read from `data/keycloak/codaxy.json` as the source of truth (override with the `REALM_EXPORT` env var to seed from another realm-export-shaped file) and skip objects that already exist on the target.

## Prerequisites

- `curl`
- `jq`

## Scripts


| Script                          | Purpose                                                             |
| ------------------------------- | ------------------------------------------------------------------- |
| `seed-client-scope.sh`          | Creates the custom `gateway_client_roles` client scope and assigns it as a default scope on the gateway and its calling clients |
| `seed-client.sh`                | Creates a client with service account and its protocol mappers from the realm export. On an existing client it adds missing protocol mappers and sets their config to match the export |
| `seed-client-roles.sh`          | Seeds a client's roles from the export (section RBAC, app roles, TMF API roles, …) |
| `seed-groups.sh`                | Seeds a client's user groups (e.g. `*-read-only`, `*-full-access`) and maps their client roles |
| `seed-service-account-roles.sh` | Assigns realm and client roles to a service account                 |
| `seed-authz-services.sh`        | Imports authorization resources, scopes, policies, permissions      |


## Environment Variables

All scripts support:


| Variable                  | Default  | Description    |
| ------------------------- | -------- | -------------- |
| `KEYCLOAK_ADMIN`          | `admin`  | Admin username |
| `KEYCLOAK_ADMIN_PASSWORD` | `admin`  | Admin password |
| `REALM`                   | `Codaxy` | Target realm   |
| `REALM_EXPORT`            | `data/keycloak/codaxy.json` | Realm export file to read definitions from |


**For the password, prefer `--password-stdin` flag to avoid leaking it into your shell history or the process list**, e.g.:

```bash
KEYCLOAK_ADMIN=custom-admin ./seed-client-scope.sh $KC --password-stdin
```

## Execution Order

When provisioning a fresh realm, run in this order:

```bash
KC=http://localhost:8080

# 1. Custom client scopes (must exist before clients reference them)
./seed-client-scope.sh $KC

# 2. Create clients
./seed-client.sh $KC cxo-admin
./seed-client.sh $KC cxo-engineering-portal
./seed-client.sh $KC cxo-tmf-api-gateway

# 3. Client roles
./seed-client-roles.sh $KC cxo-admin              # Admin Portal section roles
./seed-client-roles.sh $KC cxo-engineering-portal # Engineering Portal section roles
./seed-client-roles.sh $KC cxo-tmf-api-gateway    # TMF API Gateway API roles

# 4. User groups (must run after client roles exist)
./seed-groups.sh $KC cxo-admin                # cxo-admins-read-only / cxo-admins-full-access
./seed-groups.sh $KC cxo-engineering-portal   # cxo-engineering-portal-read-only / -full-access

# 5. Service account role mappings
./seed-service-account-roles.sh $KC cxo-admin
./seed-service-account-roles.sh $KC cxo-tmf-api-gateway
```

## ID token role mappers

`cxo-admin` and `cxo-engineering-portal` each carry their own **User Client Role** mapper writing `resource_access.<client>.roles` with **Add to ID token** on. Both portals build the user from the ID token, so they must not depend on the realm's shared `roles` scope (some realms leave **Add to ID token** off on it). If roles are assigned but not enforced, re-run `seed-client.sh <url> <client>`: it adds the mapper if it is missing, and turns **Add to ID token** on if it is off.

On `cxo-admin` this mapper serves both Admin Portal authorization modes (`Authorization:UseReadWriteRoles` and `Authorization:UseSectionPermissions`), since `cxo-admins-read` / `cxo-admins-write` and the section roles are all `cxo-admin` client roles. The former `admin_client_roles` scope (the same roles in the access token's `roles` claim) is no longer seeded: nothing reads it. Realms seeded earlier can delete it.

The demo clients (`cxo-engineering` — Demo Engineering Portal, `cxo-party-management` — Demo Party Management Engine) are not part of this realm export anymore. A deployment that needs extra clients can seed them with these scripts, pointing `REALM_EXPORT` at its own realm fragment.
