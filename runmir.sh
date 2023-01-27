#!/usr/bin/env bash

set -e

usage() {
    echo "Usage: $0 -p <protocol> [-f <F, default 0>] [-c <number of clients, default 1>]"
    echo "RUNMIR_CLIENT_ARGS is: $RUNMIR_CLIENT_ARGS"
    echo "RUNMIR_SERVER_ARGS is: $RUNMIR_SERVER_ARGS"
    exit 1
}

cleanup() {
    rm -rf "$RUNMIR_TMPDIR"
}

case "$RUNMIR_CURRENT_OP" in
    salloc)
        [ -d "$RUNMIR_TMPDIR" ] || (echo "missing variable RUNMIR_TMPDIR or it's not a path to a directory"; exit 1)
        [ -x "$RUNMIR_BENCH_EXEC" ] || (echo "missing variable RUNMIR_BENCH_EXEC or it's not a path to an executable"; exit 1)
        [ -n "$RUNMIR_PROTOCOL" ] || (echo "missing variable RUNMIR_PROTOCOL"; exit 1)
        [ -n "$RUNMIR_BATCH_SIZE" ] || (echo "missing variable RUNMIR_BATCH_SIZE"; exit 1)
        [ -n "$RUNMIR_PORT" ] || (echo "missing variable RUNMIR_PORT"; exit 1)
        [ -n "$RUNMIR_F" ] || (echo "missing variable RUNMIR_F"; exit 1)
        [ -n "$RUNMIR_N_CLIENTS" ] || (echo "missing variable RUNMIR_N_CLIENTS"; exit 1)
        [ -n "$SLURM_JOB_NODELIST_HET_GROUP_0" ] || (echo "missing variable SLURM_JOB_NODELIST_HET_GROUP_0"; exit 1)

        # parse slurm nodelist
        server_nodes="$(eval "echo $(echo "$SLURM_JOB_NODELIST_HET_GROUP_0" | sed -E 's|\],|] |g' | sed -E 's|([^0-9])([0-9]+)-([0-9]+)([^0-9])|\1{\2..\3}\4|g' | sed -E 's/\[/{/g' | sed -E 's/\]/}/g')" | tr ' ' '\n' | tr -d '{}')"

        # generate membership list
        i=0
        for hostname in $server_nodes; do
            echo "${i} /dns4/${hostname}/tcp/${RUNMIR_PORT}" >> "${RUNMIR_TMPDIR}/membership"
            i=$(( i + 1 ))
        done

        # run server nodes
	echo "$(date): starting replicas" >&2
        (
            export RUNMIR_CURRENT_OP=srun_server
            srun --het-group=0 -- "$0"
        ) &

        sleep 5 # give them some time to start up

	echo "$(date): starting clients" >&2
        # run client nodes to completion
        (
            export RUNMIR_CURRENT_OP=srun_client
            srun --het-group=1 -- "$0"
        )

	echo "$(date): clients done, cooling down" >&2
	# give it some time to cool down 
	sleep 120

        exit 0
        ;;
    srun_server)
        [ -d "$RUNMIR_TMPDIR" ] || (echo "missing variable RUNMIR_TMPDIR or it's not a path to a directory"; exit 1)
        [ -x "$RUNMIR_BENCH_EXEC" ] || (echo "missing variable RUNMIR_BENCH_EXEC or it's not a path to an executable"; exit 1)
        [ -n "$RUNMIR_PROTOCOL" ] || (echo "missing variable RUNMIR_PROTOCOL"; exit 1)
        [ -n "$RUNMIR_BATCH_SIZE" ] || (echo "missing variable RUNMIR_BATCH_SIZE"; exit 1)
        ID="$(cat "${RUNMIR_TMPDIR}/membership" | grep -E "/dns4/$(hostname)/" | cut -d' ' -f1)"

        echo "$ID = $(hostname)" >&2
        if [ -z "$ID" ]; then
            cat "${RUNMIR_TMPDIR}/membership" >&2
	fi

        exec "$RUNMIR_BENCH_EXEC" node -p "${RUNMIR_PROTOCOL}" -i "$ID" -m "${RUNMIR_TMPDIR}/membership" -b ${RUNMIR_BATCH_SIZE} --statPeriod 5s ${RUNMIR_SERVER_ARGS} | sed "s/^/n$ID,/"
        ;;

    srun_client)
        [ -d "$RUNMIR_TMPDIR" ] || (echo "missing variable RUNMIR_TMPDIR or it's not a path to a directory"; exit 1)
        [ -x "$RUNMIR_BENCH_EXEC" ] || (echo "missing variable RUNMIR_BENCH_EXEC or it's not a path to an executable"; exit 1)
        [ -n "$RUNMIR_PROTOCOL" ] || (echo "missing variable RUNMIR_PROTOCOL"; exit 1)
        [ -n "$SLURM_PROCID" ] || (echo "missing variable SLURM_PROCID"; exit 1)
	
        exec "$RUNMIR_BENCH_EXEC" client -i "$SLURM_PROCID" -m "${RUNMIR_TMPDIR}/membership" ${RUNMIR_CLIENT_ARGS}
        ;;

    *)
        export RUNMIR_TMPDIR="$(mktemp -d -p "$CLUSTER_HOME")"
        trap cleanup EXIT

        export RUNMIR_BENCH_EXEC="$(pwd)/mir/bin/bench"
        export RUNMIR_PORT=4242
        export RUNMIR_F=0
        export RUNMIR_BATCH_SIZE=1024
        export RUNMIR_N_CLIENTS=1
        export RUNMIR_CLIENT_ARGS
        export RUNMIR_PROTOCOL

        while getopts ':p:f:b:c:' OPTION; do
            case "$OPTION" in
                p)
                    RUNMIR_PROTOCOL="$OPTARG"
                    ;;
                f)
                    RUNMIR_F="$OPTARG"
                    ;;
                b)
                    RUNMIR_BATCH_SIZE="$OPTARG"
                    ;;
                c)
                    RUNMIR_N_CLIENTS="$OPTARG"
                    ;;
                ?)
                    usage
                    ;;
            esac
        done

        if [[ -z "$RUNMIR_PROTOCOL" ]] || [[ $RUNMIR_F -lt 0 ]] || [[ $RUNMIR_N_CLIENTS -le 0 ]]; then
            usage
            exit 1
        fi

        slurm_server_nodes=$(( 3 * RUNMIR_F + 1 ))
	slurm_client_tasks=$RUNMIR_N_CLIENTS

        export RUNMIR_CURRENT_OP=salloc
        salloc -x 'lab1p[1-12],lab2p[1-20],lab3p[1-10],lab4p[1-10],lab6p[1-9],lab7p[1-9]' -N $slurm_server_nodes --cpus-per-task=4 --ntasks-per-node=1 --exclusive -t 6 : \
	       -x 'lab1p[1-12],lab2p[1-20],lab3p[1-10],lab5p[1-20],lab6p[1-9],lab7p[1-9]' -n $slurm_client_tasks --cpus-per-task=1 --ntasks-per-node=4 --exclusive -t 6  -- "$0"

        rm -rf $RUNMIR_TMPDIR
        ;;
esac
