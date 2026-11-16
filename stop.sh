#!/bin/bash

set -e

# Work from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")"

# Compose resolves the project the same way startup.sh did (name: in the files, or
# COMPOSE_PROJECT_NAME from the environment or .env).
RUNNING=$(docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps -q | wc -l)
if [ "$RUNNING" -eq 0 ]; then
    echo "Nothing to stop: no running containers in this compose project."
    exit 0
fi

echo "Stopping the CxO stack ($RUNNING running containers)..."

# Try to stop stacks, including PgBouncer override if present.
# NOTE: the first invocation re-declares `db` (from the include'd db.pg.yml)
# via a second -f file. Some stricter Docker Compose versions reject that
# pattern ("conflicts with imported resource") — which is fine here, the
# fallback then handles it; PgBouncer-specific containers left behind can be
# removed with `docker compose down --remove-orphans`.
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.db.pg-with-bouncer.yml down || \
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down

LEFT=$(docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps -q | wc -l)
echo "Done. $((RUNNING - LEFT)) containers stopped and removed ($LEFT still running)."
echo "Volumes are kept. To remove them too, see db-drop-all.sh / factory-reset.sh (DESTRUCTIVE)."
