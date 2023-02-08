#!/usr/bin/env python3

import csv
from dataclasses import dataclass
import dataclasses
import os
from posixpath import basename
import sys

FIELDS = [
    'replica_idx',
    'protocol',
    'f',
    'intended_load_tps',
    'batch_size',
    #'n_clients',
    #'burst_size',
    #'received_txs_count',
    'observed_load_tps',
    #'delivered_txs_count',
    'tps',
    'avg_latency_sec',
    'mem_sys',
    'mem_stack_in_use',
    'mem_heap_alloc',
    'mem_total_alloc',
    'mem_malloc_count',
    'mem_free_count',
    'mem_pause_total_ns',
    'mem_pause_count',
]

EXP_CUT_START_PERCENT = 30
EXP_CUT_END_PERCENT = 20

@dataclass
class ExpParameter:
    name: str
    shortname: str
    parser: any
    default_value: any = None

EXP_PARAMETERS = [
    ExpParameter('protocol', 'p', lambda x: x),
    ExpParameter('f', 'f', int),
    ExpParameter('n_clients', 'c', int, 8),
    ExpParameter('intended_load_tps', 'l', int),
    ExpParameter('cooldown_time_sec', 'C', int, 60),
    ExpParameter('batch_size', 'b', int),
    ExpParameter('stat_period_sec', 'P', int, 1),
    ExpParameter('burst_size', 'B', int, 1024),
    ExpParameter('load_duration_sec', 'T', int, 120),
    ExpParameter('req_size', 's', int, 256),
]
assert len(set(ep.shortname for ep in EXP_PARAMETERS)) == len(EXP_PARAMETERS)
assert len(set(ep.name for ep in EXP_PARAMETERS)) == len(EXP_PARAMETERS)

EXP_PARAMETERS_BY_SHORTNAME = {ep.shortname:ep for ep in EXP_PARAMETERS}

ROOT='.'
def main():
    all_field_names = set(f.name for f in EXP_PARAMETERS).union(f.name for f in STAT_FIELDS)
    assert len(all_field_names) == len(EXP_PARAMETERS) + len(STAT_FIELDS)
    assert all(n in all_field_names for n in FIELDS)

    writer = csv.DictWriter(sys.stdout, FIELDS)
    writer.writeheader()

    for sub in os.scandir(ROOT):
        if not sub.is_dir():
            continue

        try:
            params = parse_exp_params_from_name(sub)
            exp_dir = sub.name
        except Exception as e:
            print(f'skipping {sub.name} due to {e}', file=sys.stderr)
            continue

        n = 3 * params["f"] + 1

        mintime = min(min(int(rec['ts']) for rec in read_raw_replica_stats(exp_dir, i)) for i in range(0, n))

        exp_cut_end_secs = params['load_duration_sec'] * (100 - EXP_CUT_END_PERCENT) // 100
        maxtime = mintime + exp_cut_end_secs * 1000

        exp_cut_start_secs = params['load_duration_sec'] * EXP_CUT_START_PERCENT // 100
        mintime += exp_cut_start_secs * 1000

        all_replica_stats = []
        for replica in range(0,n):
            raw_replica_stats = read_raw_replica_stats(exp_dir, replica)
            filtered_replica_stats = filter(time_filter(mintime, maxtime), raw_replica_stats)

            replica_stats = parse_replica_stats(map(lambda x: x, filtered_replica_stats))
            writer.writerow(filter_keys({ 'replica_idx': replica } | params | replica_stats, FIELDS))

            all_replica_stats.append(replica_stats)

        combined_stats = combine_replica_stats(all_replica_stats)
        writer.writerow(filter_keys({ 'replica_idx': -1 } | params | combined_stats, FIELDS))

def time_filter(start, end):
    return lambda rec: start <= int(rec['ts']) <= end

@dataclass
class AverageRes:
    _sum: float = 0
    _n: int = 0

    def update(self, x):
        self._sum += x
        self._n += 1
        return self

    def finalize(self) -> float:
        return self._sum / self._n

def avg_combiner(acc, x):
    if acc is None:
        acc = AverageRes()
    return acc.update(x)

def last(_acc, x):
    return x

def sum_combiner(acc, x):
    if acc is None:
        acc = 0
    return acc + x

@dataclass
class StatField:
    name: str
    mir_name: str
    parser: any
    combiner: any

STAT_FIELDS = [
    StatField('ts_ms', 'ts', int, None),
    StatField('received_txs_count', 'nrReceived', int, sum_combiner),
    StatField('observed_load_tps', 'loadtps', float, avg_combiner),
    StatField('delivered_txs_count', 'nrDelivered', int, sum_combiner),
    StatField('tps', 'tps', float, avg_combiner),
    StatField('avg_latency_sec', 'avgLatency', float, avg_combiner),
    StatField('mem_sys', 'memSys', int, last),
    StatField('mem_stack_in_use', 'memStackInUse', int, last),
    StatField('mem_heap_alloc', 'memHeapAlloc', int, last),
    StatField('mem_total_alloc', 'memTotalAlloc', int, last),
    StatField('mem_malloc_count', 'memMallocs', int, last),
    StatField('mem_free_count', 'memFrees', int, last),
    StatField('mem_pause_total_ns', 'memPauseTotalNs', int, last),
    StatField('mem_pause_count', 'memNumGC', int, last),
]
assert len(set(x.name for x in STAT_FIELDS)) == len(STAT_FIELDS)
assert len(set(x.mir_name for x in STAT_FIELDS)) == len(STAT_FIELDS)

STAT_FIELDS_BY_MIR_NAME = {f.mir_name:f for f in STAT_FIELDS}

def read_raw_replica_stats(exp_dir: str, replica: int):
    with open(f'{ROOT}/{exp_dir}/{replica}.csv', 'r') as file:
        reader = csv.DictReader(file)
        for rec in reader:
            yield rec

def parse_replica_stats(raw_stats_it):
    record = {field.name:None for field in filter(lambda f: f.combiner is not None, STAT_FIELDS)}

    for stat_rec in raw_stats_it:
        assert all(n in stat_rec for n in STAT_FIELDS_BY_MIR_NAME)

        for k, v in stat_rec.items():
            field_meta = STAT_FIELDS_BY_MIR_NAME[k]
            if field_meta.combiner is None:
                continue

            v = field_meta.parser(v)
            record[field_meta.name] = field_meta.combiner(record[field_meta.name], v)

    for k, v in record.items():
        if isinstance(v, AverageRes):
            record[k] = v.finalize()

    assert all(v is not None for v in record.values())

    return record

COMBINED_REPLICA_STATS_FIELDS = {f.name:dataclasses.replace(f) for f in STAT_FIELDS}
COMBINED_REPLICA_STATS_FIELDS['observed_load_tps'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_sys'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_stack_in_use'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_heap_alloc'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_total_alloc'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_malloc_count'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_free_count'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_pause_total_ns'].combiner = sum_combiner
COMBINED_REPLICA_STATS_FIELDS['mem_pause_count'].combiner = sum_combiner
del COMBINED_REPLICA_STATS_FIELDS['ts_ms']

def combine_replica_stats(replica_stats_it):
    record = {field.name:None for field in COMBINED_REPLICA_STATS_FIELDS.values()}

    for replica_stats in replica_stats_it:
        assert all(n in replica_stats for n in COMBINED_REPLICA_STATS_FIELDS.keys())

        for k, v in replica_stats.items():
            field_meta = COMBINED_REPLICA_STATS_FIELDS[k]
            record[field_meta.name] = field_meta.combiner(record[field_meta.name], v)

    for k, v in record.items():
        if isinstance(v, AverageRes):
            record[k] = v.finalize()

    assert all(v is not None for v in record.values())

    return record


def filter_keys(d: dict, keys: list[str]) -> dict:
    res = {}
    for k, v in d.items():
        if k in keys:
            res[k] = v

    return res

def parse_exp_params_from_name(results_path: str) -> dict[str, int | float] | None:
    bn = basename(results_path)

    params = {ep.name:ep.default_value for ep in EXP_PARAMETERS}
    for prop_asgn in bn.split(','):
        match prop_asgn.split('='):
            case [key, val]:
                param_meta = EXP_PARAMETERS_BY_SHORTNAME[key]
                params[param_meta.name] = param_meta.parser(val)
            case _:
                raise ValueError('invalid format')

    for name, val in params.items():
        if val is None:
            raise ValueError(f'missing parameter {name}')

    return params

main()
