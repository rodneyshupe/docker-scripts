#!/usr/bin/env bash

destination="/mnt/appdata"

SCRIPT_NAME=$0

FLAG_DRYRUN=0 # Set to 1 to do this as a dryrun.
FLAG_DEBUG=0 # Set to 1 to do this as a dryrun.

function usage {
  echo "Usage: ${SCRIPT_NAME} [options] [backup path]"
  if [ $# -eq 0 ] || [ -z "$1" ]; then
    echo "  -d|--debug        Run with additional debugging info"
    echo "  -D|--dryrun       Dry run"
    echo "  -h|--help         Display help"
  fi
}

function parse_arguments () {
    flag_destination_passed=0
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
            -*|--*=) # unsupported flags
                echo "ERROR: Unsupported flag $1" >&2
                echo "$(usage)" >&2
                exit 1
                ;;
            *) # preserve positional arguments
                if [ $flag_destination_passed -eq 0 ]; then
                    destination="$1"
                    flag_destination_passed=0
                    shift
                else
                    echo "ERROR: Only supply on destination folder." >&2
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
        || [[ "$path" == /bin/* ]] \
        || [[ "$path" == /mnt/* ]]; then
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

        local backup="$(sudo find $destination -maxdepth 3 -wholename "*$test" -type d)"
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
                    local destination_path="$(find_match "$source_path")"
                    if $(path_is_valid "$destination_path") ; then
                        if [ "$(ls -A "$source_path")" ]; then
                            echo "    Sync $source_path -> $destination_path..."
                            sudo rsync \
                                $([ $FLAG_DRYRUN -eq 1 ] && echo "--dry-run") \
                                --archive \
                                --checksum \
                                --perms \
                                --xattrs \
                                $([ $FLAG_DEBUG -eq 1 ] && echo "--human-readable") \
                                $([ $FLAG_DEBUG -eq 1 ] && echo "--itemize-changes") \
                                --times \
                                --modify-window=1 \
                                --exclude='*.log' \
                                --exclude='logs.*' \
                                --exclude='logs/' \
                                --exclude='*/logs' \
                                --exclude='*/cache' \
                                --exclude='cache/' \
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
                    local destination_path="$(find_match "$source_path")"
                    if $(path_is_valid "$destination_path") ; then
                        if [ "$(ls -A "$source_path")" ]; then
                            if [ -z "$source_path" ]; then
                                source_paths="$source_path"
                            else
                                source_paths="$(echo -e "$source_paths\n$source_path")"
                            fi
                        fi
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

escaped_destination=$(echo "$destination" | sed 's/\//\\\//g')

containers=$(docker container ls | grep --only-matching -e ' [a-z0-9\_\-]*$')

for container in $containers; do
    process_container "$container"
done

echo "Complete. Time Elapsed: $(secs_to_human "$(($(date +%s) - ${START_SEC}))")"
