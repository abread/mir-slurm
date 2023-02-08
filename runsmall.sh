#!/usr/bin/env bash
set -e

# ensure mir bench is up-to-date
(
	cd "${CLUSTER_HOME:-..}/mir"
	srun --cpus-per-task=4 -n1 -- make bin/bench
)
sync

source "$(dirname "$0")/lib/runscript.sh"

# also save current mir rev just in case
(
	OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
	cd "${CLUSTER_HOME:-..}/mir"
	git rev-parse HEAD > "${OUTPUT_DIR}/mir-version"
	git diff > "${OUTPUT_DIR}/mir-local-changes.patch"
	git diff --staged >> "${OUTPUT_DIR}/mir-local-changes.patch"
)

for p in alea iss; do
	runone -p $p -f 5 -l 16384 -b 1024
	runone -p $p -f 1 -l 16 -b 1024
	runone -p $p -f 5 -l 16384 -b 7680
	runone -p $p -f 2 -l 1024 -b 1024
	runone -p $p -f 2 -l 8192 -b 1024
done
