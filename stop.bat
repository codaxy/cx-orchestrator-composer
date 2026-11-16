@echo off

rem Try to stop stacks, including PgBouncer override if present
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.db.pg-with-bouncer.yml down
if errorlevel 1 (
    docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down
)

pause