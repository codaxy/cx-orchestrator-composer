#!/bin/bash 

set -e

# Work from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")"

# Firstly, get rid of cxo-conductorfrontend
docker rm -f "cxo-conductorfrontend" 2>/dev/null || echo "cxo-conductorfrontend has been removed earlier"

CERTFILE=certs/aspnetapp.pfx

if [ -z $1 ] ; then
    echo Please provide an argument:
    echo "   all - start all services, portals, and the infrastructure"
    echo "   services - start only services (and their dependencies)"
    echo "   services.tmf - start only tmf and util services (and their dependencies)"
    echo "   db - start db infrastructure"
    echo "   caching - start caching infrastructure"
    echo "   data - start db and caching infrastructure"
    echo "   monitoring - start monitoring infrastructure (Prometheus, Grafana, Loki, Tempo)"
    echo "   conductor - start Conductor on its own"
    echo "   maestro - start CxMaestro on its own"
    echo "   keycloak - start Keycloak"
    echo "   kafka - start Kafka"
    echo "   infrastructure - start the entire infrastructure (db, orchestration engine, keycloak, ...)"
    echo
    echo "Options:"
    echo "   --with-maestro - run CxMaestro instead of Conductor as the orchestration engine"
    echo "                    (for the stack targets; equivalent to CXO_ORCHESTRATOR=maestro."
    echo "                    The conductor and maestro targets name their engine already, and"
    echo "                    only one engine runs at a time either way)"
    echo "   --with-pgbouncer - use PgBouncer-based PostgreSQL (adds docker-compose.db.pg-with-bouncer.yml and removes orphans)"
    echo "   --without-monitoring - leave out the monitoring stack (Prometheus, Grafana, Loki, Tempo,"
    echo "                    OTel collector), which the stack targets include by default"
    echo "   --with-merged[=sm,rm,cdm] - run the merged Service Management, Resource Management and"
    echo "                    Common Data Management images in place of their individual services"
    echo "                    (all three, or the groups listed; for the all and services targets."
    echo "                    Equivalent to CXO_MERGED_IMAGES=sm,rm,cdm. Leaving a group out on the"
    echo "                    next run switches it back to the individual images)"
    echo "   infrastructure-pgbouncer - start the entire infrastructure with PostgreSQL via PgBouncer"
    echo "   gencert - generate self signed certificate using containers"
    echo "   gencert-dotnet - generate trusted self signed cert"
    echo
    echo Tip: When starting any stack subset, you can specify additional docker compose flags, e.g.:
    echo "   ./startup.sh all --pull=always"
    echo "   ./startup.sh gencert --build"
    exit 1
fi 

ARG=$1
shift 1
ARGS=$@

# --with-merged[=groups] is consumed here; see scripts/merged-images.sh.
source scripts/merged-images.sh
select_merged_images $ARGS || exit 1
ARGS=$MERGED_ARGS
MERGED_COMPOSE=$(merged_images_files)

# Detect optional flags in remaining args
PG_BOUNCER_COMPOSE=""
MONITORING_COMPOSE=""
REMOVE_ORPHANS=""

USE_MAESTRO=0
USE_PGBOUNCER=0
USE_MONITORING=1
for a in $ARGS ; do
    if [ "$a" = "--with-maestro" ] ; then
        USE_MAESTRO=1
    fi
    if [ "$a" = "--with-pgbouncer" ] ; then
        USE_PGBOUNCER=1
    fi
    if [ "$a" = "--without-monitoring" ] ; then
        USE_MONITORING=0
    fi
done

if [ $USE_MAESTRO -eq 1 ] ; then
    ARGS=${ARGS/--with-maestro/}
    CXO_ORCHESTRATOR=maestro
fi

# Exported rather than passed with -f, because the engine is selected by a parameterised
# include inside docker-compose.infrastructure.yml. Every target that reaches the engine
# through that include picks it up.
export CXO_ORCHESTRATOR
ORCHESTRATOR=${CXO_ORCHESTRATOR:-conductor}

# Only one orchestration engine can run at a time: both publish host ports 48081 and 45000, so
# the second one to start fails to bind. Compose replaces the engine container itself on a
# switch, because both engine files call the service `conductor`, but each engine's database
# container carries its own name and is left running.
#
# The engine being switched away from is removed by name rather than with --remove-orphans. On
# a narrow target such as `conductor`, compose would count the rest of the stack as orphans and
# take it down. Removing the container leaves its named volume, so switching back finds the
# data the other engine had.
stop_other_orchestrator() {
    local leftovers

    # A name filter matches on substrings, so a CONTAINER_PREFIX set in .env is covered without
    # the script having to read .env itself.
    if [ "$ORCHESTRATOR" = "maestro" ] ; then
        leftovers=$(docker ps --format '{{.Names}}' -f name=cxo-conductor -f name=cxo-conductordb)
    else
        leftovers=$(docker ps --format '{{.Names}}' -f name=cxo-maestro-api -f name=cxo-maestrodb)
    fi

    if [ -z "$leftovers" ] ; then
        return
    fi

    for name in $leftovers ; do
        docker rm -f "$name" > /dev/null 2>&1 || true
        echo "Stopped $name: starting the $ORCHESTRATOR engine instead"
    done

    # Reaching here means the engine is being switched, not merely started, and the services
    # already running need to know. Workflow and task definitions live in the engine's own
    # database, and a service pushes its own at startup and never again. The engine coming up
    # has an empty database, and Compose does not recreate a service whose only change is
    # which engine it depends on — so everything still running stays registered against the
    # engine just removed, and the new one looks half-configured.
    echo
    echo "  Switching engines: $ORCHESTRATOR starts with no definitions registered."
    echo "  Services already running will not re-register on their own. Restart them once"
    echo "  the engine is healthy, then confirm the count has settled:"
    echo
    echo "      docker compose -f docker-compose.yml restart"
    echo "      curl -s http://localhost:48081/api/metadata/workflow | jq length"
    echo
}

# Engine dependency overlays, selected the same way the engine itself is. They go in with -f
# rather than `include:` because Compose 2.x rejects a file that declares a service one of its
# own includes also declares, and Compose 2.x is still in wide use.
#
# Each target takes only the overlays whose services it actually starts. An overlay naming a
# service the target does not define fails with "neither an image nor a build context".
DEPENDS_PORTALS="-f docker-compose.portals.depends.$ORCHESTRATOR.yml"
DEPENDS_ENGINES="-f docker-compose.services.engines.depends.$ORCHESTRATOR.yml"
DEPENDS_UTIL="-f docker-compose.services.util.depends.$ORCHESTRATOR.yml"

if [ $USE_PGBOUNCER -eq 1 ] ; then
    ARGS=${ARGS/--with-pgbouncer/}
    PG_BOUNCER_COMPOSE="-f docker-compose.db.pg-with-bouncer.yml"
    REMOVE_ORPHANS="--remove-orphans"
fi

# Monitoring is part of the stack targets unless --without-monitoring is given. It goes in with
# -f rather than include:, because deployments that pass docker-compose.monitoring.yml themselves
# would otherwise declare its services twice, which Compose 2.x rejects. --with-monitoring is
# still accepted and changes nothing.
ARGS=${ARGS/--without-monitoring/}
ARGS=${ARGS/--with-monitoring/}
if [ $USE_MONITORING -eq 1 ] ; then
    MONITORING_COMPOSE="-f docker-compose.monitoring.yml"
fi

case $ARG in

gencert) 
    echo Executing: Generating certificates
    docker compose -f docker-compose.certificates.yml up --force-recreate -V $ARGS
    echo Executing: Certificates generated
    ;;

gencert-dotnet) 
    echo Executing: Generating certificates
    dotnet dev-certs https -ep $CERTFILE -p password
    echo Executing: Certificates generated
    ;;

all)
    if [ ! -f $CERTFILE ] ; then 
        echo Error: $CERTFILE not found. Please run "$0 gencert" or "$0 gencert-dotnet" before continuing 
        exit 1
    fi
    echo Executing: Complete startup with all services
    stop_other_orchestrator
    switch_merged_images
    docker compose -f docker-compose.yml $DEPENDS_PORTALS $DEPENDS_ENGINES $DEPENDS_UTIL $MERGED_COMPOSE $PG_BOUNCER_COMPOSE $MONITORING_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

services) 
    echo Executing: Starting microservices and their dependencies
    stop_other_orchestrator
    switch_merged_images
    docker compose -f docker-compose.services.yml $DEPENDS_ENGINES $DEPENDS_UTIL $MERGED_COMPOSE $PG_BOUNCER_COMPOSE $MONITORING_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

services.tmf) 
    echo Executing: Starting TMF microservices and their dependencies
    stop_other_orchestrator
    docker compose -f docker-compose.infrastructure.yml -f docker-compose.services.util.yml -f docker-compose.services.tmf.yml $DEPENDS_UTIL $PG_BOUNCER_COMPOSE $MONITORING_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

db)
    echo Executing: Starting DB infrastructure
    docker compose -f docker-compose.db.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

caching)
    echo Executing: Starting caching infrastructure
    docker compose -f docker-compose.caching.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

data)
    echo Executing: Starting DB and caching infrastructure
    docker compose -f docker-compose.db.yml -f docker-compose.caching.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

keycloak)
    echo Executing: Starting Keycloak
    docker compose -f docker-compose.keycloak.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

kafka)
    echo Executing: Starting Kafka
    docker compose -f docker-compose.kafka.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

monitoring)
    echo Executing: Starting monitoring infrastructure
    docker compose -f docker-compose.monitoring.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

conductor)
    # The target names the engine, so it wins over --with-maestro and over CXO_ORCHESTRATOR.
    ORCHESTRATOR=conductor
    echo "Executing: Starting Conductor"
    stop_other_orchestrator
    docker compose -f docker-compose.conductor.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

maestro)
    ORCHESTRATOR=maestro
    echo "Executing: Starting CxMaestro"
    stop_other_orchestrator
    docker compose -f docker-compose.maestro.yml $PG_BOUNCER_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;
    
infrastructure)
    echo Executing: Starting the entire infrastructure
    stop_other_orchestrator
    docker compose -f docker-compose.infrastructure.yml $PG_BOUNCER_COMPOSE $MONITORING_COMPOSE up $REMOVE_ORPHANS $ARGS -d
    ;;

infrastructure-pgbouncer)
    echo Executing: Starting the entire infrastructure using PgBouncer for PostgreSQL
    stop_other_orchestrator
    docker compose -f docker-compose.infrastructure.yml -f docker-compose.db.pg-with-bouncer.yml up $ARGS -d
    ;;

*) 
    echo Invalid argument

esac
