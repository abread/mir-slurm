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
	CLIENT_TYPE//client-type/dummy
	N_CLIENTS/c/num-clients/8
	LOAD/l/load/
	COOLDOWN/C/cooldown/60
	BATCH_SIZE/b/replica-batchSize/
	STAT_PERIOD/P/replica-statPeriod/1
	BURST/B/client-burst/1024
	DURATION/T/client-duration/120
	REQ_SIZE/s/client-reqSize/256
	REPLICA_VERBOSE/v/replica-verbose/false
	CLIENT_VERBOSE/V/client-verbose/false
	REPLICA_CPUPROFILE//replica-cpuprofile/false
	REPLICA_TRACE//replica-trace/false
	REPLICA_MEMPROFILE//replica-memprofile/false
	CLIENT_CPUPROFILE//client-cpuprofile/false
	CLIENT_MEMPROFILE//client-memprofile/false
)
opt_parse OPTS "$0" "$@"

# parse slurm nodelist
parse_slurm_nodelist() {
	local nodes="$1"

	# transform [a,b] ranges into bash expansions ({})
	nodes="$(echo "$nodes" | sed -E 's \[ { g' | sed -E 's \] } g')"

	# transform [a-b] ranges into bash expansions ({a..b})
	nodelist_transform_range() {
		echo "$1" | sed -E 's ([^0-9])([0-9]+)-([0-9]+)([^0-9]) \1{\2..\3}\4 g'
	}
	while [[ "$(nodelist_transform_range "$nodes")" != "$nodes" ]]; do
		nodes="$(nodelist_transform_range "$nodes")"
	done

	# wrap everything in {} to deal with strings such as lab1p1,lab2p{2,3}
	# which would expand to lab1p1,lab2p2 lab1p1,lab2p3
	nodes='{'"$nodes"'}'

	# expand node list
	nodes="$(eval echo "$nodes")"

	# when expanding constructs like lab1p{{1..2}}, they will result in lab1p{1} lab1p{2}
	# so we'll remove all the curly braces
	echo "$nodes" | tr -d '{}'
}

[[ -n "$SLURM_JOB_NODELIST_HET_GROUP_0" ]] || panic "missing slurm het group 0"
[[ -n "$SLURM_JOB_NODELIST_HET_GROUP_1" ]] || panic "missing slurm het group 1"

[[ -d "$OUTPUT_DIR" ]] || panic "output dir doesn't exist"

MIR_PORT=4242
REPLICA_NODES="$(parse_slurm_nodelist "$SLURM_JOB_NODELIST_HET_GROUP_0")"
MEMBERSHIP_PATH="${OUTPUT_DIR}/membership"

# generate membership list
[[ ! -f "$MEMBERSHIP_PATH" ]] || panic "membership file already exists"

REPLICA_ID=0
for hostname in $REPLICA_NODES; do
	echo "${REPLICA_ID} /dns4/${hostname}/tcp/${MIR_PORT}" >> "$MEMBERSHIP_PATH"
	REPLICA_ID=$(( REPLICA_ID + 1 ))
done

RUN_BENCH_REPLICA="$(dirname "$0")/run-bench-replica.sh"
RUN_BENCH_CLIENT="$(dirname "$0")/run-bench-client.sh"

# start replicas
echo "$(date): starting replicas" >&2
REPLICA_OUT_FILE_SPEC="${OUTPUT_DIR//%/%%}/replica-%t-%N.log"
REPLICA_ERR_FILE_SPEC="${OUTPUT_DIR//%/%%}/replica-%t-%N.err"
srun --kill-on-bad-exit=1 --het-group=0 -i none -o "$REPLICA_OUT_FILE_SPEC" -e "$REPLICA_ERR_FILE_SPEC" -- \
	"$RUN_BENCH_REPLICA" -M "$BENCH_PATH" -b "$BATCH_SIZE" -p "$PROTOCOL" -o "$OUTPUT_DIR" --statPeriod "$STAT_PERIOD" -m "$MEMBERSHIP_PATH" ${REPLICA_VERBOSE+-v} ${REPLICA_CPUPROFILE:+--cpuprofile} ${REPLICA_MEMPROFILE:+--memprofile} ${REPLICA_TRACE:+--trace} &

sleep 10 # give them some time to start up

# send a single initial request before continuing
# this ensures all sockets are properly connected between replicas
"$BENCH_PATH" client -t dummy -i 9999 -m "$MEMBERSHIP_PATH" -r 0.1 -T 1s

sleep 5 # give them some time to wind down from the initial request

# check if replicas are still alive
jobs &>/dev/null # let jobs report that it's done (if it finished early)
[[ $(jobs | wc -l) -ne 1 ]] && panic "servers terminated early"

echo "$(date): starting clients" >&2
# run client nodes to completion
CLIENT_RATE="$(python -c "print(float(${LOAD})/${N_CLIENTS})")"
CLIENT_OUT_FILE_SPEC="${OUTPUT_DIR//%/%%}/client-%t-%N.log"
CLIENT_ERR_FILE_SPEC="${OUTPUT_DIR//%/%%}/client-%t-%N.err"
srun --kill-on-bad-exit=1 --het-group=1 -n "$N_CLIENTS" -i none -o "$CLIENT_OUT_FILE_SPEC" -e "$CLIENT_ERR_FILE_SPEC" -- \
	"$RUN_BENCH_CLIENT" -M "$BENCH_PATH" -t "$CLIENT_TYPE" -b "$BURST" -T "$DURATION" -r "$CLIENT_RATE" -s "$REQ_SIZE" -m "$MEMBERSHIP_PATH" ${CLIENT_VERBOSE+-v} ${CLIENT_CPUPROFILE:+--cpuprofile} ${CLIENT_MEMPROFILE:+--memprofile}

echo "$(date): clients done, cooling down" >&2
sleep "$COOLDOWN"

# check if replicas are still alive
jobs &>/dev/null # let jobs report that it's done (if it finished early)
[[ $(jobs | wc -l) -ne 1 ]] && panic "servers terminated early"

# stop replicas
scancel -s SIGINT "$SLURM_JOBID_HET_GROUP_0" || true
wait
