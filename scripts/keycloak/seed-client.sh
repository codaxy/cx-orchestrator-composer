#!/usr/bin/env bash
set -euo pipefail

#
# Creates a Keycloak client (with service account) from data/keycloak/codaxy.json.
# Reads the full client definition, strips IDs, and POSTs it to the target.
# Idempotent — if a client with the same clientId already exists it is left
# as is, except for the protocol mappers defined for it in the export: missing
# ones are added, and config values that differ from the export are set (e.g.
# "Add to ID token" left off on the role mapper). Other mappers are not touched.
#
# Prerequisites: curl, jq
#
# Usage:
#   ./seed-client.sh <keycloak_url> <client_id>
#
# Examples:
#   ./seed-client.sh http://localhost:8080 cxo-engineering
#   ./seed-client.sh http://localhost:8080 cxo-tmf-api-gateway --password-stdin
#   KEYCLOAK_ADMIN=admin KEYCLOAK_ADMIN_PASSWORD=admin ./seed-client.sh http://localhost:8080 cxo-engineering
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

# --- Extract client definition from realm export ---
echo "Reading client '${CLIENT_ID}' from ${REALM_EXPORT}..."
CLIENT_DEF=$(jq --arg cid "${CLIENT_ID}" '.clients[] | select(.clientId == $cid)' "${REALM_EXPORT}")

if [ -z "${CLIENT_DEF}" ] || [ "${CLIENT_DEF}" = "null" ]; then
  echo "ERROR: Client '${CLIENT_ID}' not found in ${REALM_EXPORT}" >&2
  exit 1
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

# --- Check if client already exists ---
EXISTING=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id // empty')

if [ -n "${EXISTING}" ]; then
  echo "  [skip] Client '${CLIENT_ID}' already exists (UUID: ${EXISTING})"

  # Reconcile the export's protocol mappers on the existing client.
  EXISTING_MAPPERS=$(curl -sS -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${EXISTING}/protocol-mappers/models" \
    -H "Authorization: Bearer ${TOKEN}")

  while IFS= read -r mapper; do
    [ -z "${mapper}" ] && continue
    WANTED=$(echo "${CLIENT_DEF}" | jq --arg n "${mapper}" 'first(.protocolMappers[] | select(.name == $n)) | del(.id)')
    CURRENT=$(echo "${EXISTING_MAPPERS}" | jq --arg n "${mapper}" 'first(.[] | select(.name == $n)) // empty')

    if [ -z "${CURRENT}" ]; then
      HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${EXISTING}/protocol-mappers/models" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${WANTED}")
      if [ "${HTTP_CODE}" = "201" ]; then
        echo "  [created] mapper: ${mapper}"
      else
        echo "  [error] mapper: ${mapper} — HTTP ${HTTP_CODE}"
      fi
      continue
    fi

    CURRENT_TYPE=$(echo "${CURRENT}" | jq -r '.protocolMapper')
    WANTED_TYPE=$(echo "${WANTED}" | jq -r '.protocolMapper')
    if [ "${CURRENT_TYPE}" != "${WANTED_TYPE}" ]; then
      echo "  [warn] mapper: ${mapper} is a ${CURRENT_TYPE}, the export has ${WANTED_TYPE} — fix it by hand"
      continue
    fi

    # Config values that differ from the export, e.g. "id.token.claim: false -> true".
    DRIFT=$(jq -rn --argjson c "${CURRENT}" --argjson w "${WANTED}" \
      '[$w.config | to_entries[] | select($c.config[.key] != .value)
        | "\(.key): \($c.config[.key] // "unset") -> \(.value)"] | join(", ")')
    if [ -z "${DRIFT}" ]; then
      echo "  [skip] mapper: ${mapper} (up to date)"
      continue
    fi

    MAPPER_ID=$(echo "${CURRENT}" | jq -r '.id')
    UPDATED=$(jq -n --argjson c "${CURRENT}" --argjson w "${WANTED}" '$c | .config += $w.config')
    HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${EXISTING}/protocol-mappers/models/${MAPPER_ID}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${UPDATED}")
    if [ "${HTTP_CODE}" = "204" ]; then
      echo "  [updated] mapper: ${mapper} (${DRIFT})"
    else
      echo "  [error] mapper: ${mapper} — HTTP ${HTTP_CODE}"
    fi
  done < <(echo "${CLIENT_DEF}" | jq -r '.protocolMappers[]?.name')

  echo ""
  echo "Done. Client already present — only its protocol mappers were reconciled."
  exit 0
fi

# --- Build payload ---
# Strip server-generated IDs and authorizationSettings (seeded separately)
PAYLOAD=$(echo "${CLIENT_DEF}" | jq '
  del(.id) |
  del(.authorizationSettings) |
  .protocolMappers = [.protocolMappers[]? | del(.id)]
')

# --- Create client ---
echo "Creating client '${CLIENT_ID}'..."
HTTP_CODE=$(curl -sS -o /tmp/seed-client-response.json -w "%{http_code}" -X POST \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

if [ "${HTTP_CODE}" = "201" ]; then
  echo "  [created] Client '${CLIENT_ID}'"
elif [ "${HTTP_CODE}" = "409" ]; then
  echo "  [skip] Client '${CLIENT_ID}' (conflict — already exists)"
else
  echo "  [error] HTTP ${HTTP_CODE}"
  jq -r '.errorMessage // .error // .' /tmp/seed-client-response.json 2>/dev/null || true
  exit 1
fi

# --- Verify and print UUID ---
NEW_UUID=$(curl -sS -X GET \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')

echo ""
echo "Done. Client '${CLIENT_ID}' UUID: ${NEW_UUID}"
echo "  Service account enabled: $(echo "${CLIENT_DEF}" | jq -r '.serviceAccountsEnabled')"
echo "  Authorization services:  $(echo "${CLIENT_DEF}" | jq -r '.authorizationServicesEnabled // false')"
