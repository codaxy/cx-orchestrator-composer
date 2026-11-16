# Merged-image selection for startup.sh. Sourced, not run.
#
# Service Management, Resource Management and Common Data Management can each run as one
# merged image in place of their individual services, through
# docker-compose.services.merged-{sm,rm,cdm}.yml. Nothing changes unless asked for:
#
#   --with-merged              all three groups
#   --with-merged=sm,rm        only these
#   CXO_MERGED_IMAGES=sm,rm    the same, for a pipeline that sets environment
#
# Leaving a group out on the next run switches it back: its merged container is removed and
# its individual services start again. Databases, volumes and Kafka positions are untouched
# either way.

MERGED_GROUPS_ALL="sm rm cdm"

# The service each merged override adds, per group.
merged_service() {
    case "$1" in
        sm) echo servicemanagement ;;
        rm) echo resourcemanagement ;;
        cdm) echo commondatamanagement ;;
    esac
}

# Consumes --with-merged[=...] from the arguments; what is left is in MERGED_ARGS.
select_merged_images() {
    MERGED_ARGS=""
    local selected="${CXO_MERGED_IMAGES:-}" arg group var

    for arg in "$@"; do
        case "$arg" in
            --with-merged) selected="sm,rm,cdm" ;;
            --with-merged=*) selected="${arg#--with-merged=}" ;;
            *) MERGED_ARGS="$MERGED_ARGS $arg" ;;
        esac
    done

    MERGED_GROUPS=""
    for group in ${selected//,/ }; do
        case " $MERGED_GROUPS_ALL " in
            *" $group "*) MERGED_GROUPS="$MERGED_GROUPS $group" ;;
            *) echo "Error: unknown merged-image group '$group' (expected: ${MERGED_GROUPS_ALL// /, })." >&2; return 1 ;;
        esac
    done
    MERGED_GROUPS="${MERGED_GROUPS# }"

    # The monitoring stack scrapes each group's individual or merged targets to match; see
    # files/monitoring/otel-collector/targets/.
    for group in $MERGED_GROUPS_ALL; do
        var="CXO_$(echo "$group" | tr '[:lower:]' '[:upper:]')_IMAGES"
        case " $MERGED_GROUPS " in
            *" $group "*) export "$var=merged" ;;
            *) export "$var=individual" ;;
        esac
    done
}

# The -f entries for the selected groups.
merged_images_files() {
    local group
    for group in $MERGED_GROUPS; do
        printf -- '-f docker-compose.services.merged-%s.yml ' "$group"
    done
}

# The individual services a group replaces, read from the profile its override parks them
# behind, so the list cannot drift from the override files.
merged_replaced_services() {
    awk -v p="replaced-by-merged-$1" '
        /^  [a-z0-9-]+:[[:space:]]*$/ { svc = $1; sub(":", "", svc) }
        index($0, "\"" p "\"") && svc { print svc }
    ' "docker-compose.services.merged-$1.yml"
}

# Removes, by Compose label, the containers of the given services in this project. Found by
# label rather than through `docker compose`, which does not address a service whose profile is
# inactive, nor one defined only in an override that is not passed. Volumes are left alone.
remove_service_containers() {
    local project="${COMPOSE_PROJECT_NAME:-cxo-composer}" service ids removed=""
    for service in "$@"; do
        ids=$(docker ps -aq \
            --filter "label=com.docker.compose.project=$project" \
            --filter "label=com.docker.compose.service=$service")
        if [ -n "$ids" ]; then
            docker rm --force $ids > /dev/null
            removed="$removed $service"
        fi
    done
    echo "${removed# }"
}

# Before `up`: both an individual service and the merged container that replaces it publish the
# same host ports, so whichever variant is not wanted has to go first. A parked individual service
# keeps running otherwise — it is still in the project, so --remove-orphans leaves it — and a
# merged container left over from the previous run is only an orphan when monitoring or
# PgBouncer happens to switch --remove-orphans on.
switch_merged_images() {
    local group removed
    for group in $MERGED_GROUPS_ALL; do
        case " $MERGED_GROUPS " in
            *" $group "*) removed=$(remove_service_containers $(merged_replaced_services "$group")) ;;
            *) removed=$(remove_service_containers "$(merged_service "$group")") ;;
        esac
        if [ -n "$removed" ]; then
            echo "Merged images ($group): removed $removed"
        fi
    done
    if [ -n "$MERGED_GROUPS" ]; then
        echo "Merged images: ${MERGED_GROUPS// /, }"
    fi
}
