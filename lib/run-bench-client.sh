#!/usr/bin/env bash
set -e

unset BURST
unset DURATION
unset RATE
unset REQ_SIZE
ID="$SLURM_PROCID"
unset MEMBERSHIP_PATH

# parse arguments
PARSED_ARGS="$(getopt -a -n "$0" -o b:T:r:s:m: --long burst:,duration:,rate:,reqSize:,membership: -- "$@")"
VALID_ARGS=$?

[[ $VALID_ARGS -ne 0 ]] && exit 1

eval set -- "$PARSED_ARGS"
while true; do
    case "$1" in
        -b | --burst) BURST="$2"; shift 2 ;;
        -T | --duration) DURATION="$2"; shift 2 ;;
        -r | --rate) RATE="$2"; shift 2 ;;
        -s | --reqSize) REQ_SIZE="$2"; shift 2 ;;
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

for v in BURST DURATION RATE REQ_SIZE MEMBERSHIP_PATH; do
    (eval '[[ -z $'"$v"' ]]') && echo "missing $v" && exit 1
done
[[ ! -f "$MEMBERSHIP_PATH" ]] && echo "MEMBERSHIP_PATH does not exist" && exit 1

[[ -z "$ID" ]] && echo "missing ID/SLURM_PROCID" && exit 1

exec ./bench client -b "$BURST" -T "$DURATION" -r "$RATE" -s "$REQ_SIZE" -i "$ID" -m "$MEMBERSHIP_PATH"
