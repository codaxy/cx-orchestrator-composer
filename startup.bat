@echo off

rem Firstly, get rid of cxo-conductorfrontend
docker rm -f "cxo-conductorfrontend" 2>nul || echo cxo-conductorfrontend has been removed earlier

set "arg=%1"
set "certFile=certs/aspnetapp.pfx"

rem Optional flags
set "PG_BOUNCER_COMPOSE="
rem Monitoring is part of the stack targets unless --without-monitoring is given.
set "MONITORING_COMPOSE=-f docker-compose.monitoring.yml"
set "REMOVE_ORPHANS="

for %%a in (%*) do (
    if /i "%%a"=="--with-maestro" (
        set "CXO_ORCHESTRATOR=maestro"
    )
    if /i "%%a"=="--with-pgbouncer" (
        set "PG_BOUNCER_COMPOSE=-f docker-compose.db.pg-with-bouncer.yml"
        set "REMOVE_ORPHANS=--remove-orphans"
    )
    if /i "%%a"=="--without-monitoring" (
        set "MONITORING_COMPOSE="
    )
)

rem The engine is selected by a parameterised include in docker-compose.infrastructure.yml,
rem so setting the variable is all that is needed for every target that reaches the engine
rem through that include.
set "ORCHESTRATOR=conductor"
if defined CXO_ORCHESTRATOR set "ORCHESTRATOR=%CXO_ORCHESTRATOR%"

rem Engine dependency overlays, selected the same way the engine itself is. They go in with -f
rem rather than `include:` because Compose 2.x rejects a file that declares a service one of its
rem own includes also declares, and Compose 2.x is still in wide use. Each target takes only the overlays whose
rem services it actually starts.
set "DEPENDS_PORTALS=-f docker-compose.portals.depends.%ORCHESTRATOR%.yml"
set "DEPENDS_ENGINES=-f docker-compose.services.engines.depends.%ORCHESTRATOR%.yml"
set "DEPENDS_UTIL=-f docker-compose.services.util.depends.%ORCHESTRATOR%.yml"

if "%arg%" == "" (
    echo Please provide an argument:
    echo    all - start all services, portals, and the infrastructure
    echo    services - start only services and their dependencies
    echo    services.tmf - start only tmf and util services and their dependencies
    echo    db - start db infrastructure
    echo    caching - start caching infrastructure
    echo    data - start db and caching infrastructure
    echo    monitoring - start monitoring infrastructure ^(Prometheus, Grafana, Loki, Tempo^)
    echo    conductor - start Conductor on its own
    echo    maestro - start CxMaestro on its own
    echo    keycloak - start Keycloak
    echo    kafka - start Kafka
    echo    infrastructure - start the entire infrastructure: db, orchestration engine, keycloak, ...
    echo:
    echo Options:
    echo    --with-maestro - run CxMaestro instead of Conductor as the orchestration engine
    echo                     ^(for the stack targets; equivalent to CXO_ORCHESTRATOR=maestro. The
    echo                     conductor and maestro targets name their engine already, and only
    echo                     one engine runs at a time either way^)
    echo    --with-pgbouncer - use PgBouncer-based PostgreSQL ^(adds docker-compose.db.pg-with-bouncer.yml and removes orphans^)
    echo    --without-monitoring - leave out the monitoring stack ^(Prometheus, Grafana, Loki, Tempo,
    echo                     OTel collector^), which the stack targets include by default
    echo    infrastructure-pgbouncer - start the entire infrastructure with PostgreSQL via PgBouncer
    echo    gencert - generate self signed certificate using containers
    echo    gencert-dotnet - generate trusted self signed cert
    goto end
)

if /i "%arg%" == "gencert" (
    echo Executing: Generating certificates
    docker compose -f docker-compose.certificates.yml up --force-recreate -V
    echo Executing: Certificates generated
    goto end
)

if /i "%arg%" == "gencert-dotnet" (
    echo Executing: Generating certificates
    dotnet dev-certs https -ep ".\certs\aspnetapp.pfx" -p password
    echo Executing: Certificates generated
    goto end
)

if /i "%arg%" == "all" (
    if not exist "%certFile%" (
        echo Error: "%certFile%" not found. Please run "startup.bat gencert" or "startup.bat gencert-dotnet" before continuing
        goto end
    )

    echo Executing: Complete startup with all services
    call :stop_other_orchestrator
    docker compose -f docker-compose.yml %DEPENDS_PORTALS% %DEPENDS_ENGINES% %DEPENDS_UTIL% %PG_BOUNCER_COMPOSE% %MONITORING_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "services" (
    echo Executing: Starting microservices and their dependencies
    call :stop_other_orchestrator
    docker compose -f docker-compose.services.yml %DEPENDS_ENGINES% %DEPENDS_UTIL% %PG_BOUNCER_COMPOSE% %MONITORING_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "services.tmf" (
    echo Executing: Starting TMF microservices and their dependencies
    call :stop_other_orchestrator
    docker compose -f docker-compose.infrastructure.yml -f docker-compose.services.util.yml -f docker-compose.services.tmf.yml %DEPENDS_UTIL% %PG_BOUNCER_COMPOSE% %MONITORING_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "db" (
    echo Executing: Starting only postgres and pgadmin containers
    docker compose -f docker-compose.db.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "data" (
    echo Executing: Starting postgres, pgadmin and Redis containers
    docker compose -f docker-compose.db.yml -f docker-compose.caching.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "caching" (
    echo Executing: Starting only caching containers
    docker compose -f docker-compose.caching.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "keycloak" (
    echo Executing: Starting Keycloak
    docker compose -f docker-compose.keycloak.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "kafka" (
    echo Executing: Starting Kafka
    docker compose -f docker-compose.kafka.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "monitoring" (
    echo Executing: Starting monitoring infrastructure
    docker compose -f docker-compose.monitoring.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "conductor" (
    rem The target names the engine, so it wins over --with-maestro and over CXO_ORCHESTRATOR.
    set "ORCHESTRATOR=conductor"
    echo Executing: Starting Conductor
    call :stop_other_orchestrator
    docker compose -f docker-compose.conductor.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "maestro" (
    set "ORCHESTRATOR=maestro"
    echo Executing: Starting CxMaestro
    call :stop_other_orchestrator
    docker compose -f docker-compose.maestro.yml %PG_BOUNCER_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "infrastructure" (
    echo Executing: Starting the entire infrastructure
    call :stop_other_orchestrator
    docker compose -f docker-compose.infrastructure.yml %PG_BOUNCER_COMPOSE% %MONITORING_COMPOSE% up %REMOVE_ORPHANS% -d
    goto end
)

if /i "%arg%" == "infrastructure-pgbouncer" (
    echo Executing: Starting the entire infrastructure using PgBouncer for PostgreSQL
    call :stop_other_orchestrator
    docker compose -f docker-compose.infrastructure.yml -f docker-compose.db.pg-with-bouncer.yml up -d
    goto end
)

echo Invalid argument.

:end
pause
exit /b

rem Only one orchestration engine can run at a time: both publish host ports 48081 and 45000, so
rem the second one to start fails to bind. Compose replaces the engine container itself on a
rem switch, because both engine files call the service `conductor`, but each engine's database
rem container carries its own name and is left running.
rem
rem The engine being switched away from is removed by name rather than with --remove-orphans. On
rem a narrow target such as `conductor`, compose would count the rest of the stack as orphans and
rem take it down. Removing the container leaves its named volume, so switching back finds the
rem data the other engine had.
:stop_other_orchestrator
rem A name filter matches on substrings, so a CONTAINER_PREFIX set in .env is covered without
rem the script having to read .env itself.
if /i "%ORCHESTRATOR%"=="maestro" (
    set "OTHER_ENGINE=-f name=cxo-conductor -f name=cxo-conductordb"
) else (
    set "OTHER_ENGINE=-f name=cxo-maestro-api -f name=cxo-maestrodb"
)
set "ENGINE_SWITCHED="
for /f "delims=" %%n in ('docker ps --format "{{.Names}}" %OTHER_ENGINE%') do (
    docker rm -f %%n >nul 2>&1
    echo Stopped %%n: starting the %ORCHESTRATOR% engine instead
    set "ENGINE_SWITCHED=1"
)

rem Reaching here with ENGINE_SWITCHED set means the engine is being switched, not merely
rem started. Definitions live in the engine's own database and a service pushes its own at
rem startup and never again, so everything still running stays registered against the engine
rem just removed. Compose does not recreate a service whose only change is which engine it
rem depends on, so nothing restarts them on its own.
if defined ENGINE_SWITCHED (
    echo:
    echo   Switching engines: %ORCHESTRATOR% starts with no definitions registered.
    echo   Services already running will not re-register on their own. Restart them once
    echo   the engine is healthy, then confirm the count has settled:
    echo:
    echo       docker compose -f docker-compose.yml restart
    echo       curl -s http://localhost:48081/api/metadata/workflow ^| jq length
    echo:
)
goto :eof
