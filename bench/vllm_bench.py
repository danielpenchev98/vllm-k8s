"""Load test for comparing chunked-prefill settings.

Sends a seeded random sample of prompts.json (with the long system prompt) at Poisson-distributed
arrival times, streams the responses, and records TTFT, inter-token latency and throughput.

    python chunked_prefill_bench.py --label chunked-2048 --out results/chunked-2048.json
    python chunked_prefill_bench.py --summarize results/*.json
"""
import argparse
import asyncio
import json
import pathlib
import random
import time

import numpy as np
import openai
from tqdm import tqdm

BENCH_DIR = pathlib.Path(__file__).parent


async def one_request(client, model, system_prompt, prompt, max_tokens, reasoning):
    t0 = time.perf_counter()
    token_times = []
    stream = await client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt},
        ],
        max_tokens=max_tokens,
        temperature=0,
        stream=True,
        # Qwen3-style chat template switch for the <think> block.
        extra_body={"chat_template_kwargs": {"enable_thinking": reasoning}},
    )
    async for chunk in stream:
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta
        # With a --reasoning-parser, thinking tokens arrive in a separate field instead of content.
        if delta.content or getattr(delta, "reasoning_content", None) or getattr(delta, "reasoning", None):
            token_times.append(time.perf_counter())
    return {
        "ttft": token_times[0] - t0,
        "itls": np.diff(token_times).tolist(),
        "e2e": token_times[-1] - t0,
        "chunks": len(token_times),
    }


async def run(args):
    client = openai.AsyncOpenAI(base_url=args.base_url, api_key="not-needed", timeout=600)
    system_prompt = (BENCH_DIR / "system_prompt.txt").read_text()
    prompts = json.loads((BENCH_DIR / "prompts.json").read_text())
    # Seeded shuffle so every config gets the same random sample of prompts.
    random.Random(args.seed).shuffle(prompts)
    prompts = prompts[: args.num_prompts]

    # Warm up so the first measured requests don't pay for lazy initialization.
    await asyncio.gather(*(one_request(client, args.model, system_prompt, p, 16, args.reasoning) for p in prompts[:2]))

    rng = random.Random(0)
    tasks = []
    pbar = tqdm(total=len(prompts), desc=args.label, unit="req")

    def on_done(_):
        pbar.update()
        pbar.set_postfix(sent=len(tasks), in_flight=len(tasks) - pbar.n)

    start = time.perf_counter()
    for prompt in prompts:
        task = asyncio.create_task(one_request(client, args.model, system_prompt, prompt, args.max_tokens, args.reasoning))
        task.add_done_callback(on_done)
        tasks.append(task)
        await asyncio.sleep(rng.expovariate(args.rate))
    results = await asyncio.gather(*tasks)
    duration = time.perf_counter() - start
    pbar.close()

    ttft = np.array([r["ttft"] for r in results]) * 1000
    itl = np.array([x for r in results for x in r["itls"]]) * 1000
    e2e = np.array([r["e2e"] for r in results])
    summary = {
        "label": args.label,
        "rate": args.rate,
        "reasoning": args.reasoning,
        "num_requests": len(results),
        "ttft_ms_p50": float(np.percentile(ttft, 50)),
        "ttft_ms_p99": float(np.percentile(ttft, 99)),
        "itl_ms_p50": float(np.percentile(itl, 50)),
        "itl_ms_p99": float(np.percentile(itl, 99)),
        "itl_ms_max": float(itl.max()),
        "e2e_s_p50": float(np.percentile(e2e, 50)),
        "output_tok_s": sum(r["chunks"] for r in results) / duration,
        "duration_s": duration,
    }
    print(json.dumps(summary, indent=2))
    if args.out:
        pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.out).write_text(json.dumps(summary, indent=2))


def summarize(paths):
    rows = [json.loads(pathlib.Path(p).read_text()) for p in paths]
    cols = ["ttft_ms_p50", "ttft_ms_p99", "itl_ms_p50", "itl_ms_p99", "itl_ms_max", "e2e_s_p50", "output_tok_s"]
    print(f"{'config':<16}" + "".join(f"{c:>14}" for c in cols))
    for r in rows:
        print(f"{r['label']:<16}" + "".join(f"{r[c]:>14.1f}" for c in cols))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://localhost:8000/v1")
    parser.add_argument("--model", default="Qwen/Qwen3-1.7B")
    parser.add_argument("--label", default="run")
    parser.add_argument("--rate", type=float, default=4.0, help="mean request arrivals per second")
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--num-prompts", type=int, default=100)
    parser.add_argument("--seed", type=int, default=0, help="seed for shuffling prompts")
    parser.add_argument("--reasoning", action=argparse.BooleanOptionalAction, default=True,
                        help="enable the model's thinking mode (--no-reasoning to disable)")
    parser.add_argument("--out")
    parser.add_argument("--summarize", nargs="+", metavar="RESULT_JSON")
    args = parser.parse_args()

    if args.summarize:
        summarize(args.summarize)
    else:
        asyncio.run(run(args))


if __name__ == "__main__":
    main()
