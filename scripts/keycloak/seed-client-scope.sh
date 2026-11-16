#!/usr/bin/env bash
set -euo pipefail

#
# Ensures custom client scopes from data/keycloak/codaxy.json exist in the
# target Keycloak realm. Creates missing scopes with their protocol mappers.
#
# Currently seeds:
#   gateway_client_roles (oidc-usermodel-client-role-mapper → cxo-tmf-api-gateway roles),
#                        mapped into the root-level "roles" token claim and assigned as a
#                        default client scope on the gateway and the clients that call it.
#
# Prerequisites: curl, jq
#
# Usage:
#   ./seed-client-scope.sh <keycloak_url>
#   ./seed-client-scope.sh http://localhost:8080 --password-stdin
#   KEYCLOAK_ADMIN=admin KEYCLOAK_ADMIN_PASSWORD=admin ./seed-client-scope.sh http://localhost:8080
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REALM_EXPORT="${REALM_EXPORT:-${REPO_ROOT}/data/keycloak/codaxy.json}"

PASSWORD_STDIN=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--password-stdin" ]; then
    PASSWORD_STDIN=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

KEYCLOAK_URL="${1:-http://localhost:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
if [ "${PASSWORD_STDIN}" = true ]; then
  echo -n "Password: " >&2
  read -s -r KEYCLOAK_ADMIN_PASSWORD
  echo >&2
else
  KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
fi
REALM="${REALM:-Codaxy}"

# Scopes to seed (only non-default ones from our realm export)
SCOPE_NAMES=("gateway_client_roles")

# Scopes to assign as a default client scope on a specific client, so they are
# always included in that client's tokens. Format: "scope_name=client_id".
DEFAULT_SCOPE_ASSIGNMENTS=(
  "gateway_client_roles=cxo-admin"
  "gateway_client_roles=cxo-engineering"
  "gateway_client_roles=cxo-engineering-portal"
  "gateway_client_roles=cxo-tmf-api-gateway"
)

echo "Authenticating with Keycloak at ${KEYCLOAK_URL}..."
TOKEN=$(curl -sS -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_ADMIN}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ "${TOKEN}" = "null" ] || [ -z "${TOKEN}" ]; then
  echo "ERROR: Failed to authenticate" >&2
  exit 1
fi

EXISTING_SCOPES=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

created=0
skipped=0

for scope_name in "${SCOPE_NAMES[@]}"; do
  if echo "${EXISTING_SCOPES}" | grep -qxF "${scope_name}"; then
    echo "  [skip] client-scope: ${scope_name} (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  # Extract scope definition from realm export
  scope_def=$(jq --arg name "${scope_name}" '.clientScopes[] | select(.name == $name)' "${REALM_EXPORT}")
  if [ -z "${scope_def}" ] || [ "${scope_def}" = "null" ]; then
    echo "  [error] ${scope_name} not found in ${REALM_EXPORT}"
    continue
  fi

  # Build payload (strip id, keep mappers without ids)
  payload=$(echo "${scope_def}" | jq 'del(.id) | .protocolMappers = [.protocolMappers[]? | del(.id)]')

  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "  [created] client-scope: ${scope_name}"
    created=$((created + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "  [skip] client-scope: ${scope_name} (conflict)"
    skipped=$((skipped + 1))
  else
    echo "  [error] client-scope: ${scope_name} — HTTP ${HTTP_CODE}"
  fi
done

# --- Assign scopes as default on their target clients ---
for assignment in "${DEFAULT_SCOPE_ASSIGNMENTS[@]}"; do
  scope_name="${assignment%%=*}"
  client_id="${assignment#*=}"

  scope_uuid=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    -H "Authorization: Bearer ${TOKEN}" \
    | jq -r --arg name "${scope_name}" '.[] | select(.name == $name) | .id')

  client_uuid=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${client_id}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id // empty')

  if [ -z "${scope_uuid}" ] || [ "${scope_uuid}" = "null" ]; then
    echo "  [error] cannot assign default scope: '${scope_name}' not found"
    continue
  fi
  if [ -z "${client_uuid}" ]; then
    echo "  [warn] cannot assign '${scope_name}' as default: client '${client_id}' not found (seed it first)"
    continue
  fi

  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${client_uuid}/default-client-scopes/${scope_uuid}" \
    -H "Authorization: Bearer ${TOKEN}")

  if [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "  [default] ${scope_name} → ${client_id}"
  else
    echo "  [error] assign default ${scope_name} → ${client_id} — HTTP ${HTTP_CODE}"
  fi
done

echo ""
echo "Done. Created: ${created}, Skipped: ${skipped}"
