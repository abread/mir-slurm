#!/usr/bin/env bash
source "$(dirname "$0")/lib/runscript.sh"

n_cli=8
burst=1024
for f in 5 4 3 2 1 0; do
    for p in alea iss; do
        for b in 16 64 128 512; do
        (
            for l in 128 512 1024 8192 16384; do
                runone $p $f $l $n_cli $b $burst
            done
        ) &
        done
    done
done
wait

for f in 5 4 3 2 1 0; do
    for p in alea iss; do
        for b in 1024 2048 4096 8192; do
        (
            for l in 128 512 1024 8192 16384; do
                runone $p $f $l $n_cli $b $burst
            done
        ) &
        done
    done
done
wait

for f in 5 4 3 2 1 0; do
    for p in alea iss; do
        for b in 512 1024 2048 4096 8192; do
        (
            for l in 32768 65536 131072 262144 524288; do
                runone $p $f $l $n_cli $b $burst
            done
        ) &
        done
    done
done
wait

for f in 5 4 3 2 1 0; do
    for p in alea iss; do
        for b in 16384 32768 65536 131072 262144; do
        (
            for l in 16384 32768 65536 131072 262144 524288; do
                runone $p $f $l $n_cli $b $burst
            done
        )&
        done
    done
done
wait

echo "results saved in $OUTPUT_DIR"
