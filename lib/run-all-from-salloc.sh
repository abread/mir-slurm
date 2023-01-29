#!/usr/bin/env bash
set -e

panic() {
    echo "$@" >&2
    exit 1
}

source "$(dirname "$0")/opt-parser.sh"

# OPTS is used by opt_parse
# shellcheck disable=SC2034
OPTS=(
    BENCH_PATH/M/mirBenchPath/
    OUTPUT_DIR/o/outputDir/

    PROTOCOL/p/replica-protocol/
    LOAD/l/load/
    COOLDOWN/C/cooldown/60
    BATCH_SIZE/b/replica-batchSize/
    STAT_PERIOD/P/replica-statPeriod/5s
    BURST/B/client-burst/1024
    DURATION/T/client-duration/120
    REQ_SIZE/s/client-reqSize/256
)
opt_parse OPTS "$0" "$@"

[[ -n "$SLURM_JOB_NODELIST_HET_GROUP_0" ]] || panic "missing slurm het group 0"
[[ -n "$SLURM_JOB_NODELIST_HET_GROUP_1" ]] || panic "missing slurm het group 1"

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

RUN_BENCH_REPLICA="$(dirname "$0")/run-bench-replica.sh"
RUN_BENCH_CLIENT="$(dirname "$0")/run-bench-client.sh"

# start replicas
echo "$(date): starting replicas" >&2
srun --kill-on-bad-exit=1 --het-group=0 -- \
    "$RUN_BENCH_REPLICA" -M "$BENCH_PATH" -b "$BATCH_SIZE" -p "$PROTOCOL" -o "$OUTPUT_DIR" --statPeriod "$STAT_PERIOD" -m "$MEMBERSHIP_PATH" &

sleep 5 # give them some time to start up

# check if replicas are still alive
jobs &>/dev/null # let jobs report that it's done (if it finished early)
[[ $(jobs | wc -l) -ne 1 ]] && panic "servers terminated early"

echo "$(date): starting clients" >&2
# run client nodes to completion
CLIENT_RATE="$(python -c "print(float(${LOAD})/${N_CLIENTS})")"
srun --kill-on-bad-exit=1 --het-group=1 -- \
    "$RUN_BENCH_CLIENT" -M "$BENCH_PATH" -b "$BURST" -T "$DURATION" -r "$CLIENT_RATE" -s "$REQ_SIZE" -m "$MEMBERSHIP_PATH"

echo "$(date): clients done, cooling down" >&2
sleep "$COOLDOWN"

# script exit will stop replicas
