#!/usr/bin/env bash

SCRIPT_NAME=$0

FLAG_DEBUG=0
FLAG_DRYRUN=0
FLAG_CONATINER_LIST=0

HEALTH_CHECK_THRESHOLD=50

function usage {
    echo "Usage: ${SCRIPT_NAME} [options] [container list]"
    if [ $# -eq 0 ] || [ -z "$1" ]; then
        echo "  -t|--threshold    health check failures before restart"
        echo "  -d|--debug        Run with additional debugging info"
        echo "  -D|--dryrun       Dry run"
        echo "  -h|--help         Display help"
    fi
}

function parse_arguments () {
    while (( "$#" )); do
        case "$1" in
            -d|--debug)
                FLAG_DEBUG=1
                shift
                ;;
            -D|--dryrun)
                FLAG_DRYRUN=1
                shift
                ;;
            -h|--help)
                echo "$(usage)"
                shift
                exit 0
                ;;
            -t|--threshold)
                shift
                local num=$1
                if [[ $num =~ ^-?[0-9]+$ ]]; then
                    HEALTH_CHECK_THRESHOLD=$num
                    shift
                else
                    echo "ERROR: $num is not an integer."
                    exit 2
                    ;;
                fi
                ;;
            -*|--*=) # unsupported flags
                echo "ERROR: Unsupported flag $1" >&2
                echo "$(usage)" >&2
                exit 1
                ;;
            *) # preserve positional arguments
                FLAG_CONATINER_LIST=1
                shift
                ;;
        esac
    done
}

function container_status() {
    local CONTAINER_ID="$1"
    local CONTAINER_STATUS="$(docker container inspect ${CONTAINER_ID} | jq -r '.[0].State.Health.Status')"
    if [ "$CONTAINER_STATUS" == "null" ]; then
        CONTAINER_STATUS="$(docker container inspect ${CONTAINER_ID} | jq -r '.[0].State.Status')"
    fi
    echo "$CONTAINER_STATUS"
}

function check_container() {
    local CONTAINER_NAME="${1}"
    local CONTAINER_ID=$(docker container list | grep ${CONTAINER_NAME} | sed 's/^\([^ ]*\) .*/\1/')

    local CONTAINER_STATUS="$(container_status "$CONTAINER_ID")"
    
    if [ "$CONTAINER_STATUS" == "unhealthy" ] \
        && [ "$(docker container inspect ${CONTAINER_ID} | jq -r '.[0].State.Health.FailingStreak')" -gt "$HEALTH_CHECK_THRESHOLD" ]; then
        echo "Restarting ${CONTAINER_NAME} (${CONTAINER_ID})"
        if [ $FLAG_DRYRUN -eq 0 ]; then
            docker container restart ${CONTAINER_ID}
        fi
    elif [ $FLAG_DEBUG -eq 1 ]; then
        echo "${CONTAINER_NAME} (${CONTAINER_ID}): $CONTAINER_STATUS"
    fi
}

parse_arguments $@

if [ $FLAG_CONATINER_LIST -eq 0 ]; then
    containers=$(docker container ls | grep --only-matching -e ' [a-z0-9\_\-]*$')

    for container in $containers; do
        check_container "$container"
    done
else
    while (( "$#" )); do
        case "$1" in
            -*|--*=) # ignore flags
                shift
                ;;
            *) # preserve positional arguments
                check_container "$1"
                shift
                ;;
        esac
    done
fi