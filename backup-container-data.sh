#!/usr/bin/env bash

destination="/mnt/appdata"

SCRIPT_NAME=$0

FLAG_DRYRUN=0 # Set to 1 to do this as a dryrun.
FLAG_DEBUG=0  # Set to 1 to do this as a debug.
FLAG_LOGS=1   # Set to 0 to exclude logs
FLAG_CACHE=0  # Set to 1 to include cache files
FLAG_DELETE=1 # Set to 0 to not retain destination files on source

FLAG_CONTAINER_PASSED=0

SOURCE_BASE="/srv/appdata"
if [ ! -d "$SOURCE_BASE" ]; then
    SOURCE_BASE="/opt/appdata"
fi

DESTINATION_BASE="/mnt/appdata"
CONTAINER=""

function usage {
    echo "Usage: ${SCRIPT_NAME} [options] [backup path]"
    if [ $# -eq 0 ] || [ -z "$1" ]; then
        echo "  -e|--exclude-logs      Exclude logs from backup"
        echo "  -c|--include-cache     Include cache files in backup"
        echo "  -m|--retain-missing    Do not delete files on destination that do not exist on source"
        echo "  -s|--source-base       Source path to all container data (defaults to /srv/appdata)"
        echo "  -s|--destination-base  Location to match source path fro backup (defaults to /mnt/appdata)"
        echo "  --debug                Run with additional debugging info"
        echo "  -D|--dryrun            Dry run"
        echo "  -h|--help              Display help"
    fi
}

function parse_arguments () {
    while (( "$#" )); do
        case "$1" in
            -e|--exclude-logs)
                FLAG_LOGS=0
                shift
                ;;
            -c|--include-cache)
                FLAG_CACHE=1
                shift
                ;;
            -m|--do-not-delete|--retain-missing)
                FLAG_DELETE=0
                shift
                ;;
            -s|--source-base)
                shift
                if [ -d "$1" ]; then
                    SOURCE_BASE="$1"
                else
                    echo "ERROR: Source base does not exist. ($1)"
                    exit 1
                fi
                shift
                ;;
            -d|--destination-base)
                shift
                if [ -d "$1" ]; then
                    DESTINATION_BASE="$1"
                else
                    echo "ERROR: Destination base does not exist. ($1)"
                    exit 1
                fi
                shift
                ;;
            --debug)
                FLAG_DEBUG=$((FLAG_DEBUG+1))
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
            -*|--*=) # unsupported flags
                echo "ERROR: Unsupported flag $1" >&2
                echo "$(usage)" >&2
                exit 1
                ;;
            *) # preserve positional arguments
                if [ $FLAG_CONTAINER_PASSED -eq 0 ]; then
                    CONTAINER="$1"
                    FLAG_CONTAINER_PASSED=1
                    shift
                else
                    echo "ERROR: Only supply on containerr." >&2
                    echo "$(usage)" >&2
                    exit 1
                fi
                ;;
        esac
    done
}

function secs_to_human() {
    #echo "$(( ${1} / 3600 ))h $(( (${1} / 60) % 60 ))m $(( ${1} % 60 ))s"
    echo "$(( ${1} / 60 ))m $(( ${1} % 60 ))s"
}

function ensure_sudo() {
    if sudo -n true 2>/dev/null; then
        true
    else
        echo
        echo "$(log_prefix)ERROR: This script requires admin access. Rerun with sudo."
        exit 1;
    fi
}

function ensure_jq() {
    if (jq --version >/dev/null 2>&1); then
        true
    else
        echo
        echo "$(log_prefix)ERROR: This script requires 'jq'.  Please install apt-get install jq"
        exit 2;
    fi
}

function path_is_valid() {
    if [ -e "$1" ]; then
        echo "true"
    else
        echo "false"
    fi
}

function ignore_source() {
    local path="$1"
    if [[ "$path" == /var/* ]] \
        || [[ "$path" == /bin/* ]] \
        || [[ "$path" == /lib/* ]] \
        || [[ "$path" == /etc/* ]] \
        || [[ "$path" == /sys/* ]] \
        || [[ "$path" == /var/* ]] \
        || [[ "$path" == /bin/* ]] \
        || [[ "$path" == /mnt/* ]] \
        || [[ "$path" == /opt/* ]] \
        || [[ "$path" == "/proc" ]] \
        || [[ "$path" == "/etc" ]] \
        || [[ "$path" == "/sys" ]] \
        || [[ "$path" == "/var" ]] \
        || [[ "$path" == "$SOURCE_BASE" ]] \
        || [[ "$path" == "$DESTINATION_BASE" ]] \
        || [[ "$path" == "/" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

function find_match() {
    local next="$1"
    local source=""
    local test=""

    while [ -z "$source" ] && [ "$next" != "/" ]; do
        test="/$(basename "$next")$test"
        next="$(dirname "$next")"

        [ $FLAG_DEBUG -ge 2 ] && echo "DEBUG: next=$next test=$test"
        local backup="$(sudo find $DESTINATION_BASE -maxdepth 3 -wholename "*$test" -type d)"
        [ $FLAG_DEBUG -ge 2 ] && echo "DEBUG: backup=$backup"
        if [ $(echo "$backup" | wc -l) -eq 1 ]; then
            source="$next$test"
            break
        fi
    done
    if [ ! -z "$source" ] && [ ! -z "$backup" ]; then
        echo "$backup"
    fi
}

function backup_container() {
    local container="$1"
    local sources="$(docker container inspect "$container" | jq '.[].Mounts' | jq -r '.[].Source')"

    if [ ! -z "$sources" ]; then
        local source_path
        while read source_path; do
            if $(ignore_source "$source_path"); then
                echo "    Skipping mounted source \"$source_path\""
            else
                if $(path_is_valid "$source_path"); then
                    local destination_path="$(echo "$source_path" | sed -e "s|$SOURCE_BASE|$DESTINATION_BASE|")"
                    if ! $(path_is_valid "$destination_path") || [[ "$destination_path" == "$source_path" ]]; then
                        destination_path="$(find_match "$source_path")"
                    fi
                    if $(path_is_valid "$destination_path") && [[ "$destination_path" != "$source_path" ]]; then
                        if [ "$(ls -A "$source_path")" ]; then
                            echo "    Sync $source_path -> $destination_path..."
                            sudo rsync \
                                $([ $FLAG_DRYRUN -eq 1 ] && echo "--dry-run") \
                                --archive \
                                $([ $FLAG_DELETE -eq 1 ] && echo "--delete") \
                                --append-verify \
                                --checksum \
                                --perms \
                                --xattrs \
                                $([ $FLAG_DEBUG -ge 1 ] && echo "--human-readable") \
                                $([ $FLAG_DEBUG -ge 1 ] && echo "--itemize-changes") \
                                --times \
                                --modify-window=1 \
                                $([ $FLAG_LOGS -eq 1 ] && echo "--exclude='*.log'") \
                                $([ $FLAG_LOGS -eq 1 ] && echo "--exclude='logs.*'") \
                                $([ $FLAG_LOGS -eq 1 ] && echo "--exclude='logs/'") \
                                $([ $FLAG_LOGS -eq 1 ] && echo "--exclude='*/logs'") \
                                $([ $FLAG_CACHE -eq 1 ] && echo "--exclude='*/cache'") \
                                $([ $FLAG_CACHE -eq 1 ] && echo "--exclude='cache/'") \
                                "$source_path"/* "$destination_path"/
                        else
                            echo "    Skipping Sync $source_path -> $destination_path as source is empty"
                        fi
                    else
                        # Only display error if the source path contains the container name but is not a file.
                        if ( [[ "$source_path" == *"/$container/"* ]] || [[ "$source_path" == *"/$container" ]] ) && [ ! -f "$source_path" ]; then
                            echo "    ERROR: Destination Does Not Exist! path: \"$destination_path\" (Source path \"$source_path\")"
                        fi
                    fi
                else
                    echo "    WARNING: Source not found. path \"$source_path\""
                fi
            fi
        done <<< "$sources"
    fi
}

function process_container() {
    local container=$1

    local sources="$(docker container inspect "$container" | jq '.[].Mounts' | jq -r '.[].Source')"
    local source_paths=""
    if [ ! -z "$sources" ]; then
        local source_path
        while read source_path; do
            if ! $(ignore_source "$source_path"); then
                if $(path_is_valid "$source_path"); then
                    local destination_path="$(echo "$source_path" | sed -e "s|$SOURCE_BASE|$DESTINATION_BASE|")"
                    if ! $(path_is_valid "$destination_path") || [[ "$destination_path" != "$source_path" ]]; then
                        destination_path="$(find_match "$source_path")"
                    fi
                    if $(path_is_valid "$destination_path") && [[ "$destination_path" != "$source_path" ]]; then
                        if [ "$(ls -A "$source_path")" ]; then
                            source_paths="$(echo -e "$source_paths\n$source_path")"
                        else
                            [ $FLAG_DEBUG -ge 1 ] && echo "DEBUG: Empty=$source_path"
                        fi
                    else
                        [ $FLAG_DEBUG -ge 1 ] && echo "DEBUG: BadDir=$source_path|$destination_path"
                    fi
                fi
            fi
        done <<< "$sources"
    fi

    if [ -z "$source_paths" ]; then
        echo "Nothing to backup so ignoring container ($container)"
    else
        echo "Syncing App Data for $container:"
        echo "    Stopping container..."
        [ $FLAG_DRYRUN -eq 0 ] && docker container stop $container >/dev/null

        echo "    Backup container..."
        backup_container "$container"

        echo "    Restarting container..."
        [ $FLAG_DRYRUN -eq 0 ] && docker container start $container >/dev/null
    fi
}

START_SEC=$(date +%s)

ensure_jq

parse_arguments $@

echo "Start Time: $(date)"

escaped_destination=$(echo "$DESTINATION_BASE" | sed 's/\//\\\//g')
[ $FLAG_DEBUG -ge 1 ] && echo "Source Base:      $SOURCE_BASE"
[ $FLAG_DEBUG -ge 1 ] && echo "Destination Base: $DESTINATION_BASE"

if [ -z "$CONTAINER" ]; then
    containers=$(docker container ls | grep --only-matching -e ' [a-z0-9\_\-]*$')

    for container in $containers; do
        process_container "$container"
    done
else
    process_container "$CONTAINER"
fi

echo "Complete. Time Elapsed: $(secs_to_human "$(($(date +%s) - ${START_SEC}))")"
