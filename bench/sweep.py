"""Sweeps max-num-seqs x max-num-batched-tokens x request rate, one CSV row per run.

For every (max-num-seqs, max-num-batched-tokens) pair this writes an experiment file and calls
run.sh once per rate, lowest rate first. The first rate of a pair starts a fresh vLLM with that
config; the higher rates reuse it, each with its own --seed. Every run appends its row to the CSV
right away: an interrupted sweep keeps what it measured, and the same command run again only does
the runs that aren't in the CSV yet.

    .venv/bin/python bench/sweep.py            # seqs 8 16 32 64 126 x batched 512 1024 2048 x rates 1 2 4 8 16
    .venv/bin/python bench/sweep.py --seqs 16 32 --batched 1024 --rates 1 2 --name long --max-tokens 1024
    .venv/bin/python bench/sweep.py --dry-run  # only print the plan
    column -s, -t < bench/results/sweep.csv | less -S   # read the CSV

Other arguments go to vllm_bench.py (e.g. --num-prompts, --max-tokens, --no-reasoning). They are
stored in the bench_args column, so runs with a different workload never count as done.
A run is "overloaded" when requests waited in vLLM's queue longer than --overload-queue-s on
average. The pair's higher rates are then recorded as "skipped" instead of run (--keep-going runs
them anyway), since their latencies would only measure how long the queue grew.
"""
import argparse
import csv
import itertools
import json
import os
import pathlib
import shlex
import subprocess
import sys

BENCH_DIR = pathlib.Path(__file__).resolve().parent
RESULTS = BENCH_DIR / "results"
COLUMNS = [
    "max_num_seqs", "max_num_batched_tokens", "rate", "status", "achieved_req_s",
    "ttft_ms_p50", "ttft_ms_p90", "ttft_ms_p99", "itl_ms_p50", "itl_ms_p90", "itl_ms_p99", "itl_ms_max",
    "e2e_s_p50", "output_tok_s", "queue_s_mean", "preemptions", "num_requests", "num_errors",
    "duration_s", "seed", "bench_args", "label",
]
# Set per run by the sweep itself.
RESERVED = {"--rate", "--seed", "--label", "--out", "--summarize"}


def key(seqs, batched, rate, bench_args):
    return int(seqs), int(batched), float(rate), bench_args


def read_statuses(path):
    """Status of every run already in the CSV, by (seqs, batched, rate, bench_args)."""
    if not path.exists():
        return {}
    with open(path, newline="") as f:
        return {key(r["max_num_seqs"], r["max_num_batched_tokens"], r["rate"], r["bench_args"]): r["status"]
                for r in csv.DictReader(f)}


def append_row(path, row):
    new = not path.exists() or path.stat().st_size == 0
    with open(path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        if new:
            writer.writeheader()
        writer.writerow({k: round(v, 3) if isinstance(v, float) else v for k, v in row.items()})


def num_prompts(extra):
    for i, arg in enumerate(extra):
        if arg == "--num-prompts" and i + 1 < len(extra):
            return int(extra[i + 1])
        if arg.startswith("--num-prompts="):
            return int(arg.split("=", 1)[1])
    return 300  # vllm_bench.py's default


def main():
    sys.stdout.reconfigure(line_buffering=True)  # keeps our lines in order with run.sh's output
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seqs", type=int, nargs="+", default=[8, 16, 32, 64, 126], metavar="N",
                        help="max-num-seqs values (default: 8 16 32 64 126)")
    parser.add_argument("--batched", type=int, nargs="+", default=[512, 1024, 2048], metavar="N",
                        help="max-num-batched-tokens values (default: 512 1024 2048)")
    parser.add_argument("--rates", type=float, nargs="+", default=[1, 2, 4, 8, 16], metavar="R",
                        help="request rates in req/s (default: 1 2 4 8 16)")
    parser.add_argument("--name", default="sweep",
                        help="prefix of the run labels; the CSV is results/<name>.csv (default: sweep)")
    parser.add_argument("--out", type=pathlib.Path, help="CSV file to use instead of results/<name>.csv")
    parser.add_argument("--overload-queue-s", type=float, default=2.0, metavar="S",
                        help="mean queue time that marks a run overloaded (default: 2)")
    parser.add_argument("--keep-going", action="store_true", help="also run the rates above an overloaded one")
    parser.add_argument("--dry-run", action="store_true", help="print the planned runs and exit")
    args, extra = parser.parse_known_args()
    if RESERVED & {arg.split("=")[0] for arg in extra}:
        parser.error(f"{', '.join(sorted(RESERVED))} are set by the sweep")
    if not (BENCH_DIR / "prompts.json").exists():
        sys.exit("bench/prompts.json missing, generate it with: .venv/bin/python bench/gen_prompts.py")

    bench_args = shlex.join(extra)
    out = args.out or RESULTS / f"{args.name}.csv"
    done = read_statuses(out)
    rates = sorted(set(args.rates))

    plan = []  # (seqs, batched, rates still to run)
    for seqs, batched in itertools.product(args.seqs, args.batched):
        if batched < seqs:
            print(f"leaving out max-num-seqs {seqs} with max-num-batched-tokens {batched}: vLLM needs batched >= seqs")
            continue
        plan.append((seqs, batched, [r for r in rates if key(seqs, batched, r, bench_args) not in done]))

    runs = sum(len(todo) for *_, todo in plan)
    configs = sum(1 for *_, todo in plan if todo)
    minutes = (sum(num_prompts(extra) / r + 30 for *_, todo in plan for r in todo) + 120 * configs) / 60
    print(f"{runs} runs over {configs} vLLM configs, roughly {minutes:.0f} min; results in {out}")
    for seqs, batched, todo in plan:
        print(f"  max-num-seqs {seqs:>4}  max-num-batched-tokens {batched:>6}  rates: "
              + (" ".join(f"{r:g}" for r in todo) or "all done"))
    if args.dry_run or not runs:
        return

    exp_dir = RESULTS / args.name
    exp_dir.mkdir(parents=True, exist_ok=True)
    failed = []
    for p, (seqs, batched, todo) in enumerate(plan):
        if not todo:
            continue
        experiment = exp_dir / f"seqs{seqs}-b{batched}.yaml"
        experiment.write_text(f"max-num-seqs: {seqs}\nmax-num-batched-tokens: {batched}\n")
        overloaded_at = min((r for r in rates if done.get(key(seqs, batched, r, bench_args)) == "overloaded"),
                            default=None)
        fresh = True
        for rate in todo:
            label = f"{args.name}-s{seqs}-b{batched}-r{rate:g}"
            row = {"max_num_seqs": seqs, "max_num_batched_tokens": batched, "rate": rate,
                   "bench_args": bench_args, "label": label}
            if overloaded_at is not None and rate > overloaded_at and not args.keep_going:
                print(f"\n==> {label}: skipped, this config is already overloaded at {overloaded_at:g} req/s")
                append_row(out, {**row, "status": "skipped"})
                continue
            seed = 1000 + p * len(rates) + rates.index(rate)
            # A pair's first run starts from a fresh vLLM, so no earlier prompts sit in its prefix cache.
            env = {**os.environ, "FRESH": "1" if fresh else "0"}
            cmd = [str(BENCH_DIR / "run.sh"), str(experiment), label, "--rate", f"{rate:g}", "--seed", str(seed),
                   *extra]
            if subprocess.run(cmd, env=env).returncode != 0:
                print(f"\n==> {label} failed, leaving out the rest of this config")
                failed.append(label)
                break
            fresh = False
            result = json.loads((RESULTS / f"{label}.json").read_text())
            overloaded = result["queue_s_mean"] > args.overload_queue_s
            if overloaded and overloaded_at is None:
                overloaded_at = rate
            append_row(out, {**result, **row, "seed": seed, "status": "overloaded" if overloaded else "ok",
                             "achieved_req_s": result["num_requests"] / result["duration_s"]})

    print(f"\nresults: {out}")
    if failed:
        sys.exit(f"failed: {' '.join(failed)} (run the same command again to retry them)")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\ninterrupted; run the same command again to continue where it stopped")
