# TODO

Open work, roughly in order. Benchmarking comes after the Open WebUI and model-discovery items.

## Open WebUI follow-ups

- [ ] Deployment: `strategy: {type: Recreate}` (RWO PVC + SQLite, never two pods at once)
- [ ] Deployment: `startupProbe` (long, first boot downloads an embedding model) + readiness/liveness on `/health`
- [ ] Deployment: resource requests/limits; check it fits on the control-plane node next to Prometheus/Grafana
- [ ] Drop `WEBUI_URL` (only needed for OAuth/webhooks), or move it to the overlay together with the Ingress host
- [ ] `OPENAI_API_KEY`: use an obviously fake value (`unused`) instead of an `sk-proj-…` lookalike
- [ ] PVC: 1Gi → ~5Gi (embedding model cache + uploads), drop the hardcoded `namespace: llm`
- [ ] Overlay: `ingressClassName: traefik` patch for the `open-webui` Ingress (widen the target to `kind: Ingress`)
- [ ] Overlay: `storageClassName: standard` patch for `open-webui-data`, like `model-weights`
- [ ] Overlay: `webui-secret` doesn't need `disableNameSuffixHash`; restore the comment on `hf-token` explaining why it does
- [ ] Move the hostnames (`api.localhost`, `chat.localhost`) from the components into the overlay
- [ ] Disable title/tag/follow-up generation (Admin → Settings → Interface) before benchmarking
- [ ] Optional: NetworkPolicy on LiteLLM allowing only traefik (namespace) + open-webui; lives in `components/litellm/`

## Model discovery (LiteLLM `/v1/models` is empty with the `*` wildcard)

Cause: `check_provider_endpoint` can't list vLLM models, `VLLMModelInfo.get_api_key()` always returns
`None` (`litellm/llms/vllm/common_utils.py`, still the case in v1.104.0 / `main`).

- [ ] Upstream: open an issue / PR against LiteLLM for the vLLM `get_api_key` bug
- [ ] Once fixed: `litellm_settings: check_provider_endpoint: true` and keep the wildcard

### Operator that registers vLLM models in LiteLLM

- [ ] Contract: opt-in annotation on the vLLM Service (`litellm/register: "true"`); name read from the backend's `/v1/models`
- [ ] Semantics: unregister only when the Service is deleted, not on restart / scale to 0
- [ ] Pick a framework: kopf (Python) or controller-runtime/kubebuilder (Go)
- [ ] Write path, v1: operator-owned ConfigMap + rollout of LiteLLM (no fight with `kubectl apply -k`)
- [ ] Write path, v2: LiteLLM management API (`/model/new`, `/model/delete`, `/model/info`); needs Postgres
      (`STORE_MODEL_IN_DB`) + master key, which then has to reach Open WebUI, smoke test and bench scripts
- [ ] Level-triggered reconcile: desired (k8s) vs actual (LiteLLM, filtered by `managed_by`), on events + timer
- [ ] `components/litellm-operator/`: Deployment, ServiceAccount, namespaced Role (services, endpointslices, own ConfigMap, patch litellm Deployment)
- [ ] NetworkPolicy: let the operator reach vLLM `:8000` (and LiteLLM `:4000` for v2)
- [ ] Remove `model_list` from the kustomize-managed LiteLLM config
- [ ] Observability: logs, Kubernetes Events on the Service, optional `/metrics`
- [ ] Tests: fresh deploy, vLLM restart, rename `served-model-name`, delete Service, kill operator mid-change, re-run `kubectl apply -k`

## Docs

- [ ] README: API entry point is now `api.localhost:8080`, add `chat.localhost:8080`, components table, layout tree
- [ ] README: note that `*.localhost` resolves to `::1` via systemd-resolved; non-curl clients may need `127.0.0.1` + `Host` header
- [ ] `deploy.sh`: drop the leftover retry loop in `smoke_test`, add an Open WebUI `/health` check
- [ ] `docs/architecture.py`: add Open WebUI, re-render

## Later

- [ ] Benchmarking
- [ ] v2 of the operator: a CRD (`LLMModel`) with status conditions instead of annotations
- [ ] Look at the Gateway API Inference Extension (`InferencePool`) / KServe as the "real" version of the above
