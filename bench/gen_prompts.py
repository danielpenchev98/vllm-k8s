"""Expands the hand-written prompts in prompts_seed.json into a large, length-diverse prompts.json.

Each generated prompt is derived from the seeds in one of four length buckets:
  short      (~10-80 words)     first sentence / a clause of a seed, or a quick one-liner
  medium     (~80-250 words)    a seed as-is or a subset of its sentences
  long       (~500-1500 words)  several seed questions stitched into a multi-part request
  very-long  (~1500-2800 words) a "background document" built from many seeds plus a task

The very-long cap keeps system prompt (~4k tokens) + user prompt + max_tokens under the
default MAX_MODEL_LEN of 8192. Raise --max-words if you run with a larger context.

    python gen_prompts.py                       # 100000 prompts -> prompts.json
    python gen_prompts.py -n 20000 --max-words 6000
"""
import argparse
import json
import pathlib
import random
import re

BENCH_DIR = pathlib.Path(__file__).parent

# (bucket, weight)
BUCKETS = [("short", 0.30), ("medium", 0.40), ("long", 0.22), ("very-long", 0.08)]

SHORT_TEMPLATES = [
    "{s}",
    "In two sentences: {s}",
    "Quick question. {s}",
    "{s} Keep the answer brief.",
    "TL;DR please: {s}",
]
SHORT_ONE_LINERS = [
    "What is the difference between a process and a thread?",
    "Give me a regex that matches an ISO 8601 date.",
    "Translate 'good morning, how are you?' into Spanish, French and German.",
    "What does HTTP status 409 mean?",
    "Name three sorting algorithms and their average complexity.",
    "Write a haiku about Kubernetes.",
    "How many bytes are in a gibibyte?",
    "What is the capital of Australia?",
    "Explain idempotency in one paragraph.",
    "Suggest five names for a coffee shop.",
    "What is a p99 latency?",
    "Convert 72 degrees Fahrenheit to Celsius.",
    "Write a SQL query that counts rows per day in a table called events.",
    "What is the time complexity of binary search?",
    "Summarize the plot of Hamlet in three sentences.",
]
MEDIUM_PREFIXES = ["", "", "", "Please answer carefully. ", "I'd appreciate a structured answer. ",
                   "Context: I'm short on time, so prioritize the most important points. "]
LONG_INTROS = [
    "I have several related questions. Please answer each one in its own section.",
    "Our team collected the following open questions during a planning offsite. Address each of them in order.",
    "Please work through this list of requests one by one, numbering your answers to match.",
]
VERY_LONG_TASKS = [
    "Summarize the notes above into a one-page brief with the five most important themes.",
    "Based on the notes above, produce a prioritized list of the ten most important action items.",
    "Identify contradictions or overlapping topics in the notes above and group them into categories.",
    "Write an executive summary of the notes above for a non-technical audience.",
    "Extract every numeric figure mentioned in the notes above and explain what each one refers to.",
]


def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.?!])\s+", text) if s.strip()]


def words(text):
    return len(text.split())


def short(rng, seeds):
    if rng.random() < 0.2:
        return rng.choice(SHORT_ONE_LINERS)
    sents = sentences(rng.choice(seeds))
    s = sents[0] if rng.random() < 0.6 else rng.choice(sents)
    if words(s) > 60:
        s = " ".join(s.split()[: rng.randint(15, 60)]).rstrip(",;:") + "?"
    return rng.choice(SHORT_TEMPLATES).format(s=s)


def medium(rng, seeds):
    seed = rng.choice(seeds)
    sents = sentences(seed)
    if rng.random() < 0.5 or len(sents) <= 3:
        body = seed
    else:
        k = rng.randint(3, len(sents))
        keep = sorted(rng.sample(range(1, len(sents)), k - 1))
        body = " ".join([sents[0]] + [sents[i] for i in keep])
    return rng.choice(MEDIUM_PREFIXES) + body


def long_(rng, seeds, target):
    parts = [rng.choice(LONG_INTROS), ""]
    total, i = 0, 1
    for seed in rng.sample(seeds, len(seeds)):
        if total >= target:
            break
        parts.append(f"{i}. {seed}")
        total += words(seed)
        i += 1
    return "\n\n".join(parts)


def very_long(rng, seeds, target):
    notes, total = [], 0
    for seed in rng.sample(seeds, len(seeds)):
        if total >= target:
            break
        sents = sentences(seed)
        chunk = " ".join(rng.sample(sents, rng.randint(max(1, len(sents) // 2), len(sents))))
        notes.append(f"- {chunk}")
        total += words(chunk)
    return "Below are raw notes collected from many different discussions.\n\nNOTES:\n" + \
        "\n".join(notes) + "\n\nTASK: " + rng.choice(VERY_LONG_TASKS)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--num", type=int, default=100_000)
    parser.add_argument("--max-words", type=int, default=2800, help="upper bound for very-long prompts")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", default=str(BENCH_DIR / "prompts.json"))
    args = parser.parse_args()

    seeds = json.loads((BENCH_DIR / "prompts_seed.json").read_text())
    rng = random.Random(args.seed)
    names, weights = zip(*BUCKETS)
    lo_vlong = min(1500, args.max_words // 2)

    prompts, counts = [], dict.fromkeys(names, 0)
    for _ in range(args.num):
        bucket = rng.choices(names, weights)[0]
        counts[bucket] += 1
        if bucket == "short":
            p = short(rng, seeds)
        elif bucket == "medium":
            p = medium(rng, seeds)
        elif bucket == "long":
            p = long_(rng, seeds, rng.randint(500, min(1500, lo_vlong)))
        else:
            p = very_long(rng, seeds, rng.randint(lo_vlong, args.max_words - 150))
        prompts.append(p)

    pathlib.Path(args.out).write_text(json.dumps(prompts, ensure_ascii=False))
    lens = sorted(words(p) for p in prompts)
    pct = lambda q: lens[int(q * (len(lens) - 1))]
    print(f"wrote {len(prompts)} prompts to {args.out}")
    print("buckets:", counts)
    print(f"words: min={lens[0]} p10={pct(.1)} p50={pct(.5)} p90={pct(.9)} p99={pct(.99)} max={lens[-1]}")


if __name__ == "__main__":
    main()
