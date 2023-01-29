#!/usr/bin/env bash

set -e
panic() {
    echo "$@" >&2
    exit 1
}

unset LOAD
unset COOLDOWN
unset OUTPUT_DIR
unset BATCH_SIZE
unset PROTOCOL
unset STAT_PERIOD
unset BURST
unset DURATION
unset REQ_SIZE

# parse arguments
PARSED_ARGS="$(getopt -a -n "$0" -o l:C:o:b:p:P:B:T:s: --long load:,cooldown:,outputDir:,batchSize:,protocol:,statPeriod:,burst:,duration:,reqSize: -- "$@")"
VALID_ARGS=$?

[[ $VALID_ARGS -ne 0 ]] && panic "bad args"

eval set -- "$PARSED_ARGS"
while true; do
    case "$1" in
        -l | --load) LOAD="$2"; shift 2 ;;
        -C | --cooldown) COOLDOWN="$2"; shift 2 ;;
        -o | --outputDir) OUTPUT_DIR="$2"; shift 2 ;;
        -b | --batchSize) BATCH_SIZE="$2"; shift 2 ;;
        -p | --protocol) PROTOCOL="$2"; shift 2 ;;
        -P | --statPeriod) STAT_PERIOD="$2"; shift 2 ;;
        -B | --burst) BURST="$2"; shift 2 ;;
        -T | --duration) DURATION="$2"; shift 2 ;;
        -s | --reqSize) REQ_SIZE="$2"; shift 2 ;;

        # end of arguments
        --) shift; break ;;
        *)
            echo "Unexpected option: $1" >&2
            exit 1
            ;;
    esac
done

[[ $# -gt 0 ]] && panic "Unexpected options: $*"

for v in LOAD COOLDOWN OUTPUT_DIR BATCH_SIZE PROTOCOL STAT_PERIOD BURST DURATION REQ_SIZE SLURM_JOB_NODELIST_HET_GROUP_0 SLURM_JOB_NODELIST_HET_GROUP_1; do
    (eval '[[ -z $'"$v"' ]]') && panic "missing $v"
done

# set remaining params
MIR_PORT=4242
N_CLIENTS=$(echo "$SLURM_JOB_NODELIST_HET_GROUP_1" | wc -l)
MEMBERSHIP_PATH="${OUTPUT_DIR}/membership"

[[ -d "$OUTPUT_DIR" ]] || panic "output dir doesn't exist"

# parse slurm nodelist
server_nodes="$(eval "echo $(echo "$SLURM_JOB_NODELIST_HET_GROUP_0" | sed -E 's|\],|] |g' | sed -E 's|([^0-9])([0-9]+)-([0-9]+)([^0-9])|\1{\2..\3}\4|g' | sed -E 's/\[/{/g' | sed -E 's/\]/}/g')" | tr ' ' '\n' | tr -d '{}')"

# generate membership list
[[ ! -f "$MEMBERSHIP_PATH" ]] || panic "membership file already exists"

i=0
for hostname in $server_nodes; do
    echo "${i} /dns4/${hostname}/tcp/${MIR_PORT}" >> "$MEMBERSHIP_PATH"
    i=$(( i + 1 ))
done

OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
BENCH_PATH="$(realpath "$BENCH_PATH")"
cd "$(dirname "$0")"

export BENCH_PATH

# start replicas
echo "$(date): starting replicas" >&2
srun --kill-on-bad-exit=1 --het-group=0 -- \
    ./run-bench-replica.sh -b "$BATCH_SIZE" -p "$PROTOCOL" -o "$OUTPUT_DIR" --statPeriod "$STAT_PERIOD" -m "$MEMBERSHIP_PATH" &

sleep 5 # give them some time to start up

# check if replicas are still alive
jobs &>/dev/null # let jobs report that it's done (if it finished early)
[[ $(jobs | wc -l) -ne 1 ]] && panic "servers terminated early"

echo "$(date): starting clients" >&2
# run client nodes to completion
CLIENT_RATE="$(python -c "print(float(${LOAD})/${N_CLIENTS})")"
srun --kill-on-bad-exit=1 --het-group=1 -- \
    ./run-bench-client.sh -b "$BURST" -T "$DURATION" -r "$CLIENT_RATE" -s "$REQ_SIZE" -m "$MEMBERSHIP_PATH"

echo "$(date): clients done, cooling down" >&2
sleep "$COOLDOWN"

exit 0
