#!/usr/bin/env bash
set -e

# ensure mir bench is up-to-date
(
	cd "${CLUSTER_HOME:-..}/mir"
	srun -- make bin/bench
)
sync

source "$(dirname "$0")/lib/runscript.sh"

# also save current mir rev just in case
(
	OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
	cd "${CLUSTER_HOME:-..}/mir"
	git rev-parse HEAD > "${OUTPUT_DIR}/mir-version"
	git diff --staged > "${OUTPUT_DIR}/mir-local-changes.patch"
)

for b in 1024 2048 4096 7680; do # 8192 is too much
	for l in 128 512 1024 8192 16384; do
		# a client can only send around 24k transactions per second (overall)
		n_cli="$(python -c "print(ceil(float($l)/((3*$f+1)*24000)) + 1)")"
		for p in alea iss; do
			for f in 5 4 3 2 1 0; do
				runone -p $p -f $f -l $l -c $n_cli -b $b
			done
		done
	done
done

for b in 16 64 128 512; do
	for l in 128 512 1024 8192 16384; do
		# a client can only send around 24k transactions per second (overall)
		n_cli="$(python -c "print(ceil(float($l)/((3*$f+1)*24000)) + 1)")"
		for p in alea iss; do
			for f in 5 4 3 2 1 0; do
				runone -p $p -f $f -l $l -c $n_cli -b $b
			done
		done
	done
done

for b in 512 1024 2048 4096 7680; do # 8192 is too much
	for l in 32768 65536 131072 262144 524288; do
		# a client can only send around 24k transactions per second (overall)
		n_cli="$(python -c "print(ceil(float($l)/((3*$f+1)*24000)) + 1)")"
		for p in alea iss; do
			for f in 5 4 3 2 1 0; do
				runone -p $p -f $f -l $l -c $n_cli -b $b
			done
		done
	done
done
