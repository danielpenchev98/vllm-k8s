#!/usr/bin/env bash
# Starts vLLM in Docker once per chunked-prefill config, runs the load test against it,
# and prints a comparison table. Prefix caching is disabled in every run so the shared
# system prompt is really prefilled each time.
#
#   ./run_chunked_prefill.sh            # default arrival rate
#   RATE=8 ./run_chunked_prefill.sh     # heavier load
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-vllm/vllm-openai:latest}"
MODEL="${MODEL:-Qwen/Qwen3-1.7B}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
RATE="${RATE:-4}"
CONTAINER=vllm-chunk-bench
PYTHON=../.venv/bin/python
RESULTS=results

labels=(chunked-256 chunked-1024 chunked-2048 chunked-8192 no-chunking)
extra_args=(
  "--max-num-batched-tokens 256"
  "--max-num-batched-tokens 1024"
  "--max-num-batched-tokens 2048"
  "--max-num-batched-tokens 8192"
  # Without chunking the budget must fit a whole prompt, i.e. >= max-model-len.
  "--no-enable-chunked-prefill --max-num-batched-tokens ${MAX_MODEL_LEN}"
)

mkdir -p "$RESULTS" "$HOME/.cache/vllm"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

for i in "${!labels[@]}"; do
  label="${labels[$i]}"
  echo "==> $label: ${extra_args[$i]}"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  docker run -d --name "$CONTAINER" --gpus all --ipc=host -p 8000:8000 \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
    -v "$HOME/.cache/vllm:/root/.cache/vllm" \
    ${HF_TOKEN:+-e HF_TOKEN} \
    "$IMAGE" "$MODEL" \
    --max-model-len "$MAX_MODEL_LEN" \
    --no-enable-prefix-caching \
    ${extra_args[$i]} >/dev/null

  until curl -sf localhost:8000/health >/dev/null; do
    if [ -z "$(docker ps -q -f name="^${CONTAINER}$")" ]; then
      echo "vLLM exited during startup:"; docker logs --tail 50 "$CONTAINER"; exit 1
    fi
    sleep 3
  done

  "$PYTHON" chunked_prefill_bench.py --label "$label" --rate "$RATE" --out "$RESULTS/$label.json"
  docker logs "$CONTAINER" > "$RESULTS/$label.log" 2>&1
done

echo
"$PYTHON" chunked_prefill_bench.py --summarize $(printf "$RESULTS/%s.json " "${labels[@]}")
