#!/usr/bin/env bash
set -euo pipefail

#
# Seeds a client's roles from data/keycloak/codaxy.json onto the target realm.
# Reads the roles defined for the given client id in the realm export and
# creates each one (idempotent). Works for any client, e.g.:
#   cxo-admin               -> section-level RBAC roles (<section>:read / :write)
#   cxo-engineering-portal  -> section-level RBAC roles (<section>:read / :write)
#   cxo-engineering         -> application roles (Admin, ReadOnlyUser)
#   cxo-tmf-api-gateway     -> per-API read/modify roles
#
# The uma_protection role is excluded as Keycloak creates it automatically
# when authorization services are enabled on the client.
#
# Prerequisites: curl, jq
#
# Usage:
#   ./seed-client-roles.sh <keycloak_url> <client_id>
#   ./seed-client-roles.sh http://localhost:8080 cxo-admin
#   ./seed-client-roles.sh http://localhost:8080 cxo-engineering --password-stdin
#   KEYCLOAK_ADMIN=admin KEYCLOAK_ADMIN_PASSWORD=admin ./seed-client-roles.sh http://localhost:8080 cxo-tmf-api-gateway
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
CLIENT_ID="${2:-}"

if [ -z "${CLIENT_ID}" ]; then
  echo "ERROR: client id is required, e.g. cxo-admin, cxo-engineering or cxo-tmf-api-gateway" >&2
  echo "Usage: ./seed-client-roles.sh <keycloak_url> <client_id>" >&2
  exit 1
fi

KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
if [ "${PASSWORD_STDIN}" = true ]; then
  echo -n "Password: " >&2
  read -s -r KEYCLOAK_ADMIN_PASSWORD
  echo >&2
else
  KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
fi
REALM="${REALM:-Codaxy}"

# --- Extract roles from realm export (exclude uma_protection) ---
echo "Reading '${CLIENT_ID}' roles from ${REALM_EXPORT}..."
SOURCE_ROLES=$(jq --arg cid "${CLIENT_ID}" \
  '[.roles.client[$cid] // [] | .[] | select(.name != "uma_protection") | {name, description, composite, clientRole}]' \
  "${REALM_EXPORT}")
ROLE_COUNT=$(echo "${SOURCE_ROLES}" | jq 'length')
echo "  Found ${ROLE_COUNT} roles to seed"

if [ "${ROLE_COUNT}" = "0" ]; then
  echo "Nothing to do (no roles defined for '${CLIENT_ID}' in the export)."
  exit 0
fi

# --- Authenticate ---
echo "Authenticating with ${KEYCLOAK_URL}..."
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

# --- Resolve client UUID ---
echo "Looking up client UUID for '${CLIENT_ID}'..."
CLIENT_UUID=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')

if [ "${CLIENT_UUID}" = "null" ] || [ -z "${CLIENT_UUID}" ]; then
  echo "ERROR: Client '${CLIENT_ID}' not found in realm '${REALM}'" >&2
  exit 1
fi
echo "  Client UUID: ${CLIENT_UUID}"

# --- Get existing roles ---
EXISTING_ROLES=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/roles" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

created=0
skipped=0

for row in $(echo "${SOURCE_ROLES}" | jq -r '.[] | @base64'); do
  role_json=$(echo "${row}" | base64 --decode)
  role_name=$(echo "${role_json}" | jq -r '.name')

  if echo "${EXISTING_ROLES}" | grep -qxF "${role_name}"; then
    echo "  [skip] ${role_name}"
    skipped=$((skipped + 1))
    continue
  fi

  payload=$(echo "${role_json}" | jq '{name, description}')
  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/roles" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "204" ]; then
    echo "  [created] ${role_name}"
    created=$((created + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "  [skip] ${role_name} (conflict)"
    skipped=$((skipped + 1))
  else
    echo "  [error] ${role_name} — HTTP ${HTTP_CODE}"
  fi
done

echo ""
echo "Done. Created: ${created}, Skipped: ${skipped}"
