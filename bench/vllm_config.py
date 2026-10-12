"""Helpers run.sh uses to deploy an experiment config to vLLM.

An experiment file (experiments/*.yaml) holds only the `vllm serve` keys that differ from the base
config, deploy/components/vllm/vllm-config.yaml. `key: null` removes a key from the base.

    python vllm_config.py render BASE.yaml EXPERIMENT.yaml          # prints the ConfigMap (JSON)
    kubectl logs deploy/vllm | python vllm_config.py verify EXPERIMENT.yaml
"""
import argparse
import ast
import hashlib
import json
import re
import sys

import yaml


def load(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}


def render(base_path, experiment_path):
    config = {**load(base_path), **load(experiment_path)}
    # vLLM would pass a null on as the string "None"; here it means "drop this key from the base".
    config = {k: v for k, v in config.items() if v is not None}
    text = yaml.safe_dump(config, sort_keys=False)
    # Named after its content, like Kustomize does: the same config always maps to the same
    # ConfigMap, and a different one changes the Deployment's pod template, which restarts vLLM.
    name = "vllm-config-bench-" + hashlib.sha256(text.encode()).hexdigest()[:10]
    print(json.dumps({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "labels": {"app.kubernetes.io/part-of": "vllm-bench"}},
        "data": {"config.yaml": text},
    }))


def verify(experiment_path, log):
    # At startup vLLM logs every argument that differs from its default, as a Python dict.
    lines = re.findall(r"non-default args: (\{.*\})", log)
    if not lines:
        sys.exit("no 'non-default args' line in the vLLM log")
    try:
        applied = ast.literal_eval(lines[-1])
    except (ValueError, SyntaxError):
        print(f"  can't parse vLLM's non-default args, check them yourself:\n  {lines[-1]}")
        return
    overrides = {k: v for k, v in load(experiment_path).items() if v is not None}
    if not overrides:
        print("  no overrides, the base config as is")
    mismatches = []
    for key, want in overrides.items():
        name = key.replace("-", "_")
        if name not in applied:
            print(f"  {key}: not among vLLM's non-default args (fine if {want!r} is vLLM's default)")
        elif applied[name] in (want, [want]):
            print(f"  {key}: {want!r} ok")
        else:
            mismatches.append(f"{key}: expected {want!r}, vLLM runs with {applied[name]!r}")
    if mismatches:
        sys.exit("vLLM doesn't run the experiment's values (do the Deployment's container args override them?):\n  "
                 + "\n  ".join(mismatches))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("render", help="base config + experiment overrides -> ConfigMap manifest")
    p.add_argument("base")
    p.add_argument("experiment")
    p = sub.add_parser("verify", help="check the vLLM log (stdin) shows the experiment's values")
    p.add_argument("experiment")
    args = parser.parse_args()

    if args.cmd == "render":
        render(args.base, args.experiment)
    else:
        verify(args.experiment, sys.stdin.read())


if __name__ == "__main__":
    main()
