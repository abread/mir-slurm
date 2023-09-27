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

	PROTOCOL/p/protocol/
	N_CLIENTS/c/num-clients/1
	BATCH_SIZE/b/batchSize/
	DURATION/D/duration/120
	REQ_SIZE/s/reqSize/256
	VERBOSE/v/verbose/false
	CPUPROFILE//cpuprofile/false
	TRACE//trace/false
	MEMPROFILE//memprofile/false
	CRYPTO_IMPL_TYPE//crypto-impl-type/pseudo
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

[[ -n "$SLURM_JOB_NODELIST" ]] || panic "missing slurm job nodelist"

[[ -d "$OUTPUT_DIR" ]] || panic "output dir doesn't exist"

export MIR_PORT=4242
REPLICA_NODES="$(parse_slurm_nodelist "$SLURM_JOB_NODELIST")"
MEMBERSHIP_PATH="${OUTPUT_DIR}/membership"

# generate membership list
[[ ! -f "$MEMBERSHIP_PATH" ]] || panic "membership file already exists"

echo '{ "configuration_number": 0, "validators": [' > "$MEMBERSHIP_PATH"

REPLICA_ID=0
for hostname in $REPLICA_NODES; do
	[[ $REPLICA_ID -gt 0 ]] && echo -n ',' >> "$MEMBERSHIP_PATH"

	cat <<-EOS >> "$MEMBERSHIP_PATH"
		{
			"addr": "${REPLICA_ID}",
			"net_addr": "/dns4/${hostname}/tcp/${MIR_PORT}",
			"weight": "1"
		}
	EOS

	REPLICA_ID=$(( REPLICA_ID + 1 ))
done
echo ']}' >> "$MEMBERSHIP_PATH"

CONFIG_PATH="${OUTPUT_DIR}/config.json"
"$BENCH_PATH" params -m "$MEMBERSHIP_PATH" -o "$CONFIG_PATH" TxGen.ClientID '' TxGen.PayloadSize "$REQ_SIZE" TxGen.NumClients "$N_CLIENTS" Duration "${DURATION}s" Trantor.Mempool.MaxTransactionsInBatch "$BATCH_SIZE" Trantor.Protocol "$PROTOCOL" CryptoImpl "$CRYPTO_IMPL_TYPE" ThreshCryptoImpl "$CRYPTO_IMPL_TYPE"

RUN_BENCH_REPLICA="$(dirname "$0")/run-bench-replica.sh"

# start replicas
echo "$(date): starting replicas" >&2
REPLICA_OUT_FILE_SPEC="${OUTPUT_DIR//%/%%}/replica-%n-%N.log"
REPLICA_ERR_FILE_SPEC="${OUTPUT_DIR//%/%%}/replica-%n-%N.err"
srun --kill-on-bad-exit=1 -i none -o "$REPLICA_OUT_FILE_SPEC" -e "$REPLICA_ERR_FILE_SPEC" -- \
	"$RUN_BENCH_REPLICA" -M "$BENCH_PATH" -o "$OUTPUT_DIR" -m "$MEMBERSHIP_PATH" -c "${CONFIG_PATH}" ${REPLICA_VERBOSE+-v} ${REPLICA_CPUPROFILE:+--cpuprofile} ${REPLICA_MEMPROFILE:+--memprofile} ${REPLICA_TRACE:+--trace}
