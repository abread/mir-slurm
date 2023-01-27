#!/bin/bash

RES_DIR="results_$(date +"%F_%R:%S")"
mkdir $RES_DIR

echo "will save results in $RES_DIR"
cp "$0" "${RES_DIR}/runall-saved.sh"
cp "$(dirname "$0")/runmir.sh" "${RES_DIR}/runmir-saved.sh"


runone() {
    local p=$1
    local f=$2
    local l=$3
    local n_cli=$4
    local b=$5

    r="$(( l / n_cli ))"

    local out_name="${p}_f${f}_l${l}_b${b}_ncli${n_cli}_burst${burst}_120s"
    export RUNMIR_CLIENT_ARGS="-T 120s -b $burst -r $r"

    last_attempt="$(date '+%s')"
    echo "./runmir.sh -p $p -c $n_cli -b $b -f $f with client args: ${RUNMIR_CLIENT_ARGS} -> $out_name"
    
    attempt=0
    while (! ./runmir.sh -p $p -c $n_cli -b $b -f $f > "${RES_DIR}/${out_name}.csv" 2> "${RES_DIR}/${out_name}.err") || [[ $(wc -l < "${RES_DIR}/${out_name}.csv") -lt 40 ]] || grep "Usage:" "${RES_DIR}/${out_name}.err" >/dev/null || grep 'Requested' "${RES_DIR}/${out_name}.err"; do
        if [[ $attempt -gt 5 ]]; then
            echo "RUNMIR_CLIENT_ARGS=\"${RUNMIR_CLIENT_ARGS}\" ./runmir-saved.sh -p $p -c $n_cli -b $b -f $f > \"./${out_name}.csv\" 2> \"./${out_name}.err\"" >> "${RES_DIR}/retry_failed.sh"
	    exit 1
        fi

        sleep 15
	mv "${RES_DIR}/${out_name}.err"{,.bak}
	mv "${RES_DIR}/${out_name}.csv"{,.bak}
        echo "./runmir.sh -p $p -c $n_cli -b $b -f $f with client args: ${RUNMIR_CLIENT_ARGS} -> $out_name"
    done
}

n_cli=8
burst=1024
for f in 5 4 3 2 1 0; do
    for p in alea iss; do
        for b in 16 64 128 512; do 
        (
            for l in 128 512 1024 8192 16384; do
                runone $p $f $l $n_cli $b
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
                runone $p $f $l $n_cli $b
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
                runone $p $f $l $n_cli $b
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
                runone $p $f $l $n_cli $b
            done
        )&
        done
    done
done
wait

echo "results saved in $RES_DIR"
