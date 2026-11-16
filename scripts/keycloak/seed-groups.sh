#!/usr/bin/env bash
set -euo pipefail

#
# Seeds user groups for a given client from data/keycloak/codaxy.json.
# Selects every group in the export whose clientRoles reference the given
# client id, creates it (idempotent), and assigns the mapped client roles.
#
# For example, for cxo-admin it seeds:
#   cxo-admins-read-only   -> all <section>:read roles on cxo-admin
#   cxo-admins-full-access -> all <section>:write roles on cxo-admin
# and for cxo-engineering:
#   cxo-engineering-read-only   -> ReadOnlyUser
#   cxo-engineering-full-access -> Admin
#
# The client roles must already exist (run seed-client-roles-*.sh first).
#
# Prerequisites: curl, jq
#
# Usage:
#   ./seed-groups.sh <keycloak_url> <client_id>
#   ./seed-groups.sh http://localhost:8080 cxo-admin
#   ./seed-groups.sh http://localhost:8080 cxo-engineering --password-stdin
#   KEYCLOAK_ADMIN=admin KEYCLOAK_ADMIN_PASSWORD=admin ./seed-groups.sh http://localhost:8080 cxo-admin
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
  echo "ERROR: client id is required, e.g. cxo-admin or cxo-engineering" >&2
  echo "Usage: ./seed-groups.sh <keycloak_url> <client_id>" >&2
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

# --- Select groups that reference this client from the realm export ---
echo "Reading groups referencing '${CLIENT_ID}' from ${REALM_EXPORT}..."
SOURCE_GROUPS=$(jq --arg cid "${CLIENT_ID}" \
  '[.groups[] | select(.clientRoles | has($cid)) | {name, realmRoles, clientRoles}]' \
  "${REALM_EXPORT}")
GROUP_COUNT=$(echo "${SOURCE_GROUPS}" | jq 'length')
echo "  Found ${GROUP_COUNT} group(s) to seed"

if [ "${GROUP_COUNT}" = "0" ]; then
  echo "Nothing to do."
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

# --- Resolve a client UUID (no cache: bash 3.2, the macOS default, has no associative arrays) ---
resolve_client_uuid() {
  local cid="$1"
  local uuid
  uuid=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${cid}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')
  if [ "${uuid}" = "null" ] || [ -z "${uuid}" ]; then
    echo ""
    return
  fi
  echo "${uuid}"
}

created=0
skipped=0

for grow in $(echo "${SOURCE_GROUPS}" | jq -r '.[] | @base64'); do
  group_json=$(echo "${grow}" | base64 --decode)
  group_name=$(echo "${group_json}" | jq -r '.name')

  echo "Group '${group_name}':"

  # --- Create the group (idempotent) ---
  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${group_name}\"}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "204" ]; then
    echo "  [created] group"
    created=$((created + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "  [skip] group (already exists)"
    skipped=$((skipped + 1))
  else
    echo "  [error] group — HTTP ${HTTP_CODE}, skipping role assignment"
    continue
  fi

  # --- Resolve group UUID ---
  GROUP_UUID=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups?search=${group_name}&exact=true" \
    -H "Authorization: Bearer ${TOKEN}" \
    | jq -r --arg n "${group_name}" '.[] | select(.name == $n) | .id' | head -n1)

  if [ -z "${GROUP_UUID}" ] || [ "${GROUP_UUID}" = "null" ]; then
    echo "  [error] could not resolve group UUID for '${group_name}'"
    continue
  fi

  # --- Assign client roles ---
  for cid in $(echo "${group_json}" | jq -r '.clientRoles | keys[]'); do
    cuuid=$(resolve_client_uuid "${cid}")
    if [ -z "${cuuid}" ]; then
      echo "  [error] client '${cid}' not found, skipping its role mappings"
      continue
    fi

    # Available roles on the client, name -> full role representation.
    CLIENT_ROLES_JSON=$(curl -sS -X GET \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${cuuid}/roles" \
      -H "Authorization: Bearer ${TOKEN}")

    # Build the array of role representations to map (only roles that exist).
    WANTED=$(echo "${group_json}" | jq -c --arg cid "${cid}" '.clientRoles[$cid]')
    PAYLOAD=$(jq -n \
      --argjson available "${CLIENT_ROLES_JSON}" \
      --argjson wanted "${WANTED}" \
      '[ $available[] | select(.name as $n | $wanted | index($n)) | {id, name} ]')

    MAP_COUNT=$(echo "${PAYLOAD}" | jq 'length')
    WANT_COUNT=$(echo "${WANTED}" | jq 'length')

    if [ "${MAP_COUNT}" -lt "${WANT_COUNT}" ]; then
      MISSING=$(jq -n --argjson a "${CLIENT_ROLES_JSON}" --argjson w "${WANTED}" \
        '[ $w[] | select([ $a[].name ] | index(.) | not) ] | join(", ")')
      echo "  [warn] ${cid}: ${MISSING} not found on client (run seed-client-roles first)"
    fi

    if [ "${MAP_COUNT}" = "0" ]; then
      continue
    fi

    HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/groups/${GROUP_UUID}/role-mappings/clients/${cuuid}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}")

    if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "204" ]; then
      echo "  [mapped] ${MAP_COUNT} '${cid}' role(s)"
    else
      echo "  [error] mapping '${cid}' roles — HTTP ${HTTP_CODE}"
    fi
  done
done

echo ""
echo "Done. Groups created: ${created}, skipped: ${skipped}"
