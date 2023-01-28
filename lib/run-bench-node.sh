#!/usr/bin/env bash
set -e

unset BATCH_SIZE
unset PROTOCOL
unset STAT_FILE
unset STAT_PERIOD
unset MEMBERSHIP_PATH

# parse arguments
PARSED_ARGS="$(getopt -a -n "$0" -o b:p:o: --long batchSize:,protocol:,statFile:,statPeriod:,membership: -- "$@")"
VALID_ARGS=$?

[[ $VALID_ARGS -ne 0 ]] && exit 1

eval set -- "$PARSED_ARGS"
while true; do
    case "$1" in
        -b | --batchSize) BATCH_SIZE="$2"; shift 2 ;;
        -p | --protocol) PROTOCOL="$2"; shift 2 ;;
        -o | --statFile) STAT_FILE="$2"; shift 2 ;;
             --statPeriod) STAT_PERIOD="$2"; shift 2 ;;
        -m | --membership) MEMBERSHIP_PATH="$2"; shift 2 ;;

        # end of arguments
        --) shift; break ;;
        *)
            echo "Unexpected option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo "Unexpected options: $*" >&2
    exit 1
fi

for v in BATCH_SIZE PROTOCOL STAT_FILE STAT_PERIOD MEMBERSHIP_PATH; do
    (eval '[[ -z $'"$v"' ]]') && echo "missing $v" && exit 1
done
[[ ! -f "$MEMBERSHIP_PATH" ]] && echo "MEMBERSHIP_PATH does not exist" && exit 1


ID="$(grep -E "/dns4/$(hostname)/" "${MEMBERSHIP_PATH}" | cut -d' ' -f1)"

[[ -z "$ID" ]] && echo "could not compute replica ID for $(hostname)" && exit 1

echo "$(hostname) has ID $ID" >&2

./bench node -b "$BATCH_SIZE" -p "$PROTOCOL" -o "$STAT_FILE" --statPeriod "$STAT_PERIOD" -i "$ID" -m "$MEMBERSHIP_PATH" \
    |& sed "s|^|Node $ID/$(hostname): |"
