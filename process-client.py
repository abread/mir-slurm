#!/usr/bin/env python3

import csv
from dataclasses import dataclass
import dataclasses
import os
from posixpath import basename
import math
import sys

FIELDS = [
    'protocol',
    'client_type',
    'f',
    'intended_load_tps',
    'batch_size',
    #'burst_size',
    #'n_clients',
    'runno',
    'client_idx',
    #'delivered_txs_count',
    'tps',
    'avg_latency_sec',
    'ok',
]

EXP_CUT_START_PERCENT = 30
EXP_CUT_END_PERCENT = 20

@dataclass
class ExpParameter:
    name: str
    shortname: str
    parser: any
    default_value: any = None

def client_type(s: str) -> str:
    if s == "dummy":
        return "bc"
    return s

EXP_PARAMETERS = [
    ExpParameter('protocol', 'p', lambda x: x),
    ExpParameter('f', 'f', int),
    ExpParameter('n_clients', 'c', int, 24),
    ExpParameter('intended_load_tps', 'l', int),
    ExpParameter('cooldown_time_sec', 'C', int, 45),
    ExpParameter('batch_size', 'b', int),
    ExpParameter('stat_period_sec', 'P', int, 1),
    ExpParameter('burst_size', 'B', int, 1024),
    ExpParameter('load_duration_sec', 'T', int, 120),
    ExpParameter('req_size', 's', int, 256),
    ExpParameter('runno', 'i', int, 0),
    ExpParameter('client_type', '-client-type', client_type, "bc"),
]
assert len(set(ep.shortname for ep in EXP_PARAMETERS)) == len(EXP_PARAMETERS)
assert len(set(ep.name for ep in EXP_PARAMETERS)) == len(EXP_PARAMETERS)

EXP_PARAMETERS_BY_SHORTNAME = {ep.shortname:ep for ep in EXP_PARAMETERS}

ROOT='.'
def main():
    all_field_names = set(f.name for f in EXP_PARAMETERS).union(f.name for f in STAT_FIELDS).union(['client_idx', 'ok'])
    assert len(all_field_names) == len(EXP_PARAMETERS) + len(STAT_FIELDS) + 2
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

        if params["n_clients"] > (params["intended_load_tps"] / 256 + 1):
            params["n_clients"] = params["intended_load_tps"] // 256 + 1
        n = params["n_clients"]

        mintime = min(min(float(rec['ts']) for rec in read_raw_client_stats(exp_dir, i)) for i in range(0, n))

        exp_cut_end_secs = params['load_duration_sec'] * (100 - EXP_CUT_END_PERCENT) // 100
        maxtime = mintime + exp_cut_end_secs

        exp_cut_start_secs = params['load_duration_sec'] * EXP_CUT_START_PERCENT // 100
        mintime += exp_cut_start_secs

        all_client_stats = []
        for client in range(0,n):
            raw_client_stats = read_raw_client_stats(exp_dir, client)
            filtered_client_stats = filter(time_filter(mintime, maxtime), raw_client_stats)

            client_stats = parse_client_stats(map(lambda x: x, filtered_client_stats))
            writer.writerow(filter_keys({ 'client_idx': client } | params | client_stats, FIELDS))

            all_client_stats.append(client_stats)

        combined_stats = combine_client_stats(all_client_stats)
        writer.writerow(filter_keys({ 'client_idx': -1 } | params | combined_stats, FIELDS))

def time_filter(start, end):
    return lambda rec: start <= float(rec['ts']) <= end

@dataclass
class AverageRes:
    _sum: float = 0
    _n: int = 0
    _ok: bool = True

    def update(self, x):
        if x < 0 or math.isnan(x):
            self._ok = False
            return self

        self._sum += x
        self._n += 1
        return self

    def finalize(self) -> float:
        if self._n == 0:
            return math.nan
        return self._sum / self._n

    def ok(self) -> bool:
        return self._ok

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
    StatField('ts_s', 'ts', float, None),
    StatField('delivered_txs_count', 'nrDelivered', int, avg_combiner),
    StatField('tps', 'tps', float, avg_combiner),
    StatField('avg_latency_sec', 'avgLatency', float, avg_combiner),
]
assert len(set(x.name for x in STAT_FIELDS)) == len(STAT_FIELDS)
assert len(set(x.mir_name for x in STAT_FIELDS)) == len(STAT_FIELDS)

STAT_FIELDS_BY_MIR_NAME = {f.mir_name:f for f in STAT_FIELDS}

def read_raw_client_stats(exp_dir: str, client: int):
    with open(f'{ROOT}/{exp_dir}/client-{client}.csv', 'r') as file:
        reader = csv.DictReader(file)
        for rec in reader:
            yield rec

def parse_client_stats(raw_stats_it):
    record = {field.name:None for field in filter(lambda f: f.combiner is not None, STAT_FIELDS)}
    record["ok"] = None

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
            if k == "avg_latency_sec":
                record["ok"] = v.ok()
            record[k] = v.finalize()

    assert all(v is not None for v in record.values())

    return record

def op_and(x, y):
    if x is None:
        return y
    return x and y

COMBINED_CLIENT_STATS_FIELDS = {f.name:dataclasses.replace(f) for f in STAT_FIELDS}
COMBINED_CLIENT_STATS_FIELDS['ok'] = StatField('ok', 'ok', bool, op_and)
COMBINED_CLIENT_STATS_FIELDS['delivered_txs_count'].combiner = sum_combiner
COMBINED_CLIENT_STATS_FIELDS['tps'].combiner = sum_combiner
del COMBINED_CLIENT_STATS_FIELDS['ts_s']

def combine_client_stats(client_stats_it):
    record = {field.name:None for field in COMBINED_CLIENT_STATS_FIELDS.values()}

    for client_stats in client_stats_it:
        assert all(n in client_stats for n in COMBINED_CLIENT_STATS_FIELDS.keys())

        for k, v in client_stats.items():
            field_meta = COMBINED_CLIENT_STATS_FIELDS[k]
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
