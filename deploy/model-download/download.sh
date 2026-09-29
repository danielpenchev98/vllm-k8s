#!/usr/bin/env bash
# Usage: deploy/model-download/download.sh <model-id> [revision]   (revision: commit SHA to pin; default main)
set -euo pipefail

export MODEL_ID="$1"
export MODEL_REVISION="${2:-main}"
export MODEL_NAME="$(basename "${MODEL_ID}" | tr '[:upper:].' '[:lower:]-')"   # Qwen/Qwen3-4B -> qwen3-4b
# Job specs are immutable, so replace any previous run of the same model (hf download resumes).
kubectl -n llm delete job "model-download-${MODEL_NAME}" --ignore-not-found
envsubst '$MODEL_ID $MODEL_REVISION $MODEL_NAME' < "$(dirname "$0")/job.yaml" | kubectl apply -f -
JOB="job/model-download-${MODEL_NAME}"
# Logs exist once the container has started (first run also pulls the image); a finished
# container still has them, so this can't miss a download that completes quickly.
until kubectl -n llm logs "${JOB}" >/dev/null 2>&1; do sleep 2; done
kubectl -n llm logs -f "${JOB}" || true
# The log stream ends when the container exits; the Job's condition is the real result
# (restartPolicy OnFailure may retry before giving up).
while :; do
  case "$(kubectl -n llm get "${JOB}" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')" in
    *Complete*) echo "Downloaded ${MODEL_ID}@${MODEL_REVISION} to /models/${MODEL_NAME}"; break ;;
    *Failed*)   echo "Download failed: kubectl -n llm describe ${JOB}" >&2; exit 1 ;;
  esac
  sleep 5
done