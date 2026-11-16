#!/usr/bin/env bash
set -euo pipefail

#
# Assigns realm roles and client roles to a client's service account user,
# based on data/keycloak/codaxy.json.
#
# Reads the service account user entry from the realm export (matched by
# serviceAccountClientId) and ensures all listed realm/client role mappings
# are present on the target.
#
# Prerequisites: curl, jq
#
# Usage:
#   ./seed-service-account-roles.sh <keycloak_url> <client_id>
#
# Examples:
#   ./seed-service-account-roles.sh http://localhost:8080 cxo-engineering
#   ./seed-service-account-roles.sh http://localhost:8080 cxo-engineering --password-stdin
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

KEYCLOAK_URL="${1:-}"
CLIENT_ID="${2:-}"

if [ -z "${KEYCLOAK_URL}" ] || [ -z "${CLIENT_ID}" ]; then
  echo "Usage: $0 <keycloak_url> <client_id> [--password-stdin]"
  echo ""
  echo "Example:"
  echo "  $0 http://localhost:8080 cxo-engineering"
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

# --- Extract service account user from realm export ---
echo "Reading service account for '${CLIENT_ID}' from ${REALM_EXPORT}..."
SA_USER=$(jq --arg cid "${CLIENT_ID}" '.users[] | select(.serviceAccountClientId == $cid)' "${REALM_EXPORT}")

if [ -z "${SA_USER}" ] || [ "${SA_USER}" = "null" ]; then
  echo "ERROR: No service account user found for client '${CLIENT_ID}' in ${REALM_EXPORT}" >&2
  exit 1
fi

# default-roles-<realm> is named after the export's realm, and Keycloak grants
# the target realm's own default role to every new service account anyway.
SA_REALM_ROLES=$(echo "${SA_USER}" | jq -r '[.realmRoles[]? | select(startswith("default-roles-") | not)]')
SA_CLIENT_ROLES=$(echo "${SA_USER}" | jq -r '.clientRoles // {}')

echo "  Realm roles: $(echo "${SA_REALM_ROLES}" | jq -r 'join(", ")')"
echo "  Client role mappings: $(echo "${SA_CLIENT_ROLES}" | jq -r 'keys | join(", ")')"

# --- Authenticate ---
echo ""
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

# --- Resolve target client UUID and service account user ID ---
CLIENT_UUID=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')

if [ "${CLIENT_UUID}" = "null" ] || [ -z "${CLIENT_UUID}" ]; then
  echo "ERROR: Client '${CLIENT_ID}' not found in realm '${REALM}'" >&2
  exit 1
fi

SA_USER_ID=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/service-account-user" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.id')

if [ "${SA_USER_ID}" = "null" ] || [ -z "${SA_USER_ID}" ]; then
  echo "ERROR: Service account not found for client '${CLIENT_ID}'. Is serviceAccountsEnabled=true?" >&2
  exit 1
fi
echo "  Service account user ID: ${SA_USER_ID}"

# --- Assign realm roles ---
echo ""
echo "--- Assigning realm roles ---"

realm_created=0
realm_skipped=0

EXISTING_REALM_ROLES=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${SA_USER_ID}/role-mappings/realm" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

# Get all available realm roles for ID lookup
ALL_REALM_ROLES=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/roles" \
  -H "Authorization: Bearer ${TOKEN}")

for role_name in $(echo "${SA_REALM_ROLES}" | jq -r '.[]'); do
  if echo "${EXISTING_REALM_ROLES}" | grep -qxF "${role_name}"; then
    echo "  [skip] realm: ${role_name}"
    realm_skipped=$((realm_skipped + 1))
    continue
  fi

  role_obj=$(echo "${ALL_REALM_ROLES}" | jq --arg n "${role_name}" '[.[] | select(.name == $n)] | .[0]')
  if [ -z "${role_obj}" ] || [ "${role_obj}" = "null" ]; then
    echo "  [error] realm: ${role_name} — role not found on target"
    continue
  fi

  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${SA_USER_ID}/role-mappings/realm" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "[${role_obj}]")

  if [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "  [assigned] realm: ${role_name}"
    realm_created=$((realm_created + 1))
  else
    echo "  [error] realm: ${role_name} — HTTP ${HTTP_CODE}"
  fi
done

echo "  Realm roles — assigned: ${realm_created}, skipped: ${realm_skipped}"

# --- Assign client roles ---
echo ""
echo "--- Assigning client roles ---"

client_created=0
client_skipped=0

for target_client_id in $(echo "${SA_CLIENT_ROLES}" | jq -r 'keys[]'); do
  # Resolve target client UUID
  target_uuid=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${target_client_id}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')

  if [ "${target_uuid}" = "null" ] || [ -z "${target_uuid}" ]; then
    echo "  [error] Client '${target_client_id}' not found — skipping its roles"
    continue
  fi

  # Get roles already assigned
  existing_client_roles=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${SA_USER_ID}/role-mappings/clients/${target_uuid}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

  # Get all available roles on this client for ID lookup
  available_roles=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${target_uuid}/roles" \
    -H "Authorization: Bearer ${TOKEN}")

  roles_to_assign=$(echo "${SA_CLIENT_ROLES}" | jq -r --arg cid "${target_client_id}" '.[$cid][]')

  for role_name in ${roles_to_assign}; do
    if echo "${existing_client_roles}" | grep -qxF "${role_name}"; then
      echo "  [skip] ${target_client_id}: ${role_name}"
      client_skipped=$((client_skipped + 1))
      continue
    fi

    role_obj=$(echo "${available_roles}" | jq --arg n "${role_name}" '[.[] | select(.name == $n)] | .[0]')
    if [ -z "${role_obj}" ] || [ "${role_obj}" = "null" ]; then
      echo "  [error] ${target_client_id}: ${role_name} — role not found on target"
      continue
    fi

    HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${SA_USER_ID}/role-mappings/clients/${target_uuid}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "[${role_obj}]")

    if [ "${HTTP_CODE}" = "204" ] || [ "${HTTP_CODE}" = "200" ]; then
      echo "  [assigned] ${target_client_id}: ${role_name}"
      client_created=$((client_created + 1))
    else
      echo "  [error] ${target_client_id}: ${role_name} — HTTP ${HTTP_CODE}"
    fi
  done
done

echo "  Client roles — assigned: ${client_created}, skipped: ${client_skipped}"

# --- Summary ---
echo ""
echo "Done."
echo "  Realm roles:  assigned=${realm_created} skipped=${realm_skipped}"
echo "  Client roles: assigned=${client_created} skipped=${client_skipped}"
