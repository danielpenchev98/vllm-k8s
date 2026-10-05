<div align="center">

# vllm-k8s

**A local, GPU-backed LLM platform on Kubernetes: vLLM + LiteLLM + Open WebUI, with monitoring.**

[![Kubernetes](https://img.shields.io/badge/Kubernetes-kind%20%2B%20nvkind-326CE5?logo=kubernetes&logoColor=white)](https://github.com/NVIDIA/nvkind)
[![vLLM](https://img.shields.io/badge/vLLM-v0.30.0-30A2FF)](https://github.com/vllm-project/vllm)
[![LiteLLM](https://img.shields.io/badge/LiteLLM-v1.103.0-6E56CF)](https://github.com/BerriAI/litellm)
[![Open WebUI](https://img.shields.io/badge/Open%20WebUI-v0.11.4-000000)](https://github.com/open-webui/open-webui)
[![NVIDIA GPU Operator](https://img.shields.io/badge/GPU%20Operator-v26.7.1-76B900?logo=nvidia&logoColor=white)](https://github.com/NVIDIA/gpu-operator)
[![Prometheus](https://img.shields.io/badge/kube--prometheus--stack-91.8.2-E6522C?logo=prometheus&logoColor=white)](https://github.com/prometheus-community/helm-charts)

[Quick start](#quick-start) •
[Architecture](#architecture) •
[Day-to-day](#day-to-day) •
[Limitations](#limitations) •
[Roadmap](docs/todo.md)

</div>

---

Runs on a single Linux machine with one NVIDIA GPU, as a two-node [kind](https://kind.sigs.k8s.io/)
cluster: one node for the GPU workload, one for everything else. It serves `Qwen/Qwen3-4B` as
`qwen3-4b`.

| | Endpoint | What you get |
|---|---|---|
| 🔌 | `http://api.localhost:8080/v1` | OpenAI-compatible API (LiteLLM → vLLM) |
| 💬 | `http://chat.localhost:8080` | Chat UI (Open WebUI) |
| 📊 | `http://grafana.localhost:8080` | Dashboards and alerts (Grafana) |

## Highlights

- **Real GPU scheduling.** The NVIDIA GPU Operator advertises `nvidia.com/gpu`, and a tainted GPU node keeps
  everything except vLLM off it.
- **Gateway in front of the model.** Clients talk to LiteLLM; NetworkPolicies only let LiteLLM and
  Prometheus reach vLLM.
- **Weights survive rebuilds.** The model is downloaded once into a fixed host folder that every new
  cluster reuses.
- **Config as code.** vLLM engine flags live in one YAML file, and Grafana dashboards and alerts are
  kustomize-managed ConfigMaps and PrometheusRules.
- **GPU-aware observability.** DCGM, vLLM `/metrics`, cAdvisor and kube-state-metrics feed two
  dashboards and a slow-request alert.

## Quick start

> [!NOTE]
> **Prerequisites:** Linux, Docker Engine, Go, an NVIDIA driver on the host, and a
> [Hugging Face token](https://huggingface.co/settings/tokens).

**1. Install the tools and create the cluster**

```bash
infra/local/install-deps.sh     # once per machine
infra/local/setup-infra.sh      # once per cluster
```

**2. Add the secrets** (both files are gitignored)

```bash
echo "HF_TOKEN=hf_..." > deploy/overlays/local-kind/hf.env
echo "WEBUI_SECRET_KEY=$(openssl rand -hex 32)" > deploy/overlays/local-kind/webui.env
```

**3. Deploy**

```bash
deploy/deploy.sh                # downloads the model, deploys the stack, runs a smoke test
```

**4. Try it**

```bash
curl http://api.localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model": "qwen3-4b", "messages": [{"role": "user", "content": "Say hi /no_think"}]}'
```

- **Chat:** open <http://chat.localhost:8080>. The first account to sign up becomes the admin.
- **Grafana:** open <http://grafana.localhost:8080> as `admin`. Get the password with:

  ```bash
  kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
  ```

## Architecture

<p align="center">
  <img src="docs/architecture.png" alt="System diagram" width="900">
</p>

The host's Docker runs the two kind nodes as containers. Docker cgroup limits split the host's CPUs
and memory between them, and only the GPU node gets the GPU. That node is tainted, so only pods that
tolerate `workload=gpu-decoder` run on it: vLLM, the model download and the GPU Operator daemons.
Everything else runs on the control-plane node.

| Flow | Path |
|---|---|
| **API** | client → `api.localhost:8080` → kind port mapping → traefik (NodePort 30080) → LiteLLM → vLLM |
| **Chat** | browser → `chat.localhost:8080` → traefik → Open WebUI → LiteLLM → vLLM |
| **Model** | download Job → Hugging Face → `model-weights` PVC → vLLM (read-only) |
| **Metrics** | vLLM `/metrics`, DCGM, cAdvisor, kube-state-metrics, node-exporter → Prometheus → Grafana / Alertmanager |

<details>
<summary><b>Components</b></summary>

<br>

| Component | Namespace | Node | Installed by | Purpose |
|---|---|---|---|---|
| vLLM | `llm` | GPU | `deploy.sh` | Model server, OpenAI API on :8000 |
| model-download Job | `llm` | GPU | `deploy.sh` | `hf download` into the `model-weights` PVC |
| LiteLLM | `llm` | control-plane | `deploy.sh` | Gateway in front of vLLM, Ingress `api.localhost` |
| Open WebUI | `llm` | control-plane | `deploy.sh` | Chat UI on top of LiteLLM, Ingress `chat.localhost` |
| vLLM ServiceMonitor + NetworkPolicy | `llm` | – | `deploy.sh` | Lets Prometheus scrape vLLM `/metrics` |
| traefik | `traefik` | control-plane | `setup-infra.sh` | Ingress controller on NodePort 30080 |
| NVIDIA GPU Operator | `gpu-operator` | both | `setup-infra.sh` | Device plugin, DCGM exporter, GPU feature discovery (driver + toolkit come from host/nvkind) |
| kube-prometheus-stack | `monitoring` | control-plane (node-exporter: both) | `setup-infra.sh` | Prometheus, Grafana, Alertmanager, operator, kube-state-metrics |
| Dashboards + alerts | `monitoring` | – | `setup-infra.sh` | "Workloads: CPU / RAM / GPU" and "vLLM" dashboards, `VLLMSlowRequests` alert |
| descheduler | `kube-system` | control-plane | `setup-infra.sh` | Evicts pods that failed GPU admission after a restart |

</details>

<details>
<summary><b>Repository layout</b></summary>

```
infra/local/                  kind cluster + cluster-wide services (kind-specific)
  install-deps.sh             NVIDIA Container Toolkit, kind, nvkind, kubectl, helm, k9s, uv
  setup-infra.sh              cluster, cgroup limits, GPU Operator, traefik, descheduler, monitoring
  teardown-infra.sh           deletes the cluster (keeps PVC data in /home/kind/storage)
  common.sh                   versions, node sizes, shared helpers
  kind-config.yaml            node layout, labels, taints, system-reserved, port mapping
  *-values.yaml               Helm values per chart
deploy/                       the LLM stack (kustomize)
  base/                       namespace only
  components/vllm/            vLLM Deployment, Service, PVC, engine config (vllm-config.yaml)
  components/litellm/         LiteLLM Deployment, Service, Ingress, NetworkPolicy, model list (config.yaml)
  components/open-webui/      Open WebUI Deployment, Service, Ingress, PVC
  components/vllm-monitoring/ ServiceMonitor + NetworkPolicy for Prometheus (needs the CRDs)
  overlays/local-kind/        picks the components, adds kind specifics, model-weights PV, secrets
  model-download/             Job that downloads the model onto the PVC
  deploy.sh                   preflight, PVC, download, apply, smoke test
observability/
  dashboards/                 Grafana dashboards as code (ConfigMaps via kustomize)
  alerts/                     PrometheusRules
bench/                        load-test scripts (chunked prefill comparison)
docs/                         architecture diagram, notes, todo
```

</details>

<details>
<summary><b>Regenerating the diagram</b></summary>

<br>

The diagram is generated from `docs/architecture.py` with [diagrams](https://github.com/mingrammer/diagrams)
(needs Graphviz). It doesn't show Open WebUI yet.

```bash
uv run --no-project --with diagrams python docs/architecture.py
```

</details>

## Day-to-day

| Task | Command |
|---|---|
| Apply manifest changes in `deploy/` | `SKIP_DOWNLOAD=1 deploy/deploy.sh` or `kubectl apply -k deploy/overlays/local-kind` |
| Change vLLM engine settings | Edit `deploy/components/vllm/vllm-config.yaml`, then apply (the ConfigMap hash rolls the pod) |
| Rename or add a model in LiteLLM | Edit `deploy/components/litellm/config.yaml`, then apply |
| Update dashboards or alerts | Edit `observability/`, then `kubectl apply -k observability` |
| Upgrade one Helm release | `source infra/local/common.sh`, then run that release's `helm upgrade` from `setup-infra.sh` |
| Tear down | `infra/local/teardown-infra.sh` |

> [!WARNING]
> `kubectl apply` never deletes objects that were removed from the manifests. Delete renamed or
> dropped objects by hand.

## Limitations

### 🎮 GPU

**One GPU, used only by vLLM.**
`nvidia.com/gpu: 1` claims the whole GPU, so any other GPU pod stays Pending while vLLM runs. That
includes the `nvidia-smi` test pod in `setup-infra.sh`, so re-running that script on a live cluster
fails.
→ *Workaround:* upgrade Helm releases one at a time instead of re-running `setup-infra.sh`.

**vLLM can fail to start after a host or Docker restart.**
The kubelet re-admits pods before the device plugin has re-registered the GPU, so vLLM fails with
`UnexpectedAdmissionError`. The descheduler evicts such pods once they're `Failed`.
→ *Workaround:* run `kubectl delete pod` for pods stuck in `Unknown`.

**VRAM always looks full.**
vLLM preallocates 92% of the GPU at startup (`gpu-memory-utilization: 0.92`).
→ *Workaround:* use the KV-cache usage panel on the vLLM dashboard to see real usage.

### 🌐 Networking

**`*.localhost` may resolve only to IPv6.**
kind listens on `127.0.0.1:8080`, but with systemd-resolved, `*.localhost` can resolve to `::1`.
curl and browsers handle this; some other clients don't.
→ *Workaround:* call `http://127.0.0.1:8080` with a `Host: api.localhost` header.

**The API has no authentication.**
LiteLLM runs without a master key, so anyone who can reach `api.localhost:8080` can use the model.
That's fine on `127.0.0.1`, but not for anything exposed beyond the machine.

**Prometheus can reach all of vLLM, not only `/metrics`.**
NetworkPolicy filters by port (L4), so the rule that lets Prometheus in opens all of port 8000.

### 🧠 Models

**The LiteLLM model list is static.**
Every vLLM model has to be added by hand to `components/litellm/config.yaml`. A `*` wildcard would
route requests, but LiteLLM can't list vLLM's models, so `/v1/models` and Open WebUI's model picker
would be empty. A fix is planned in [`docs/todo.md`](docs/todo.md).

### 📈 Metrics

**Node CPU and memory show the host, not the node.**
kind nodes share the host's `/proc`, so node-exporter reports every host CPU on both nodes. The
kubelet also ignores the Docker cpuset. `system-reserved` in `kind-config.yaml` brings allocatable
down to the real node size, and `check_nodes` warns when the two differ. Per-pod CPU and memory
(cAdvisor) and GPU metrics (DCGM) are accurate.

**GPU metrics are per device, not per pod.**
DCGM labels a GPU's metrics with the pod it's allocated to. With GPU time-slicing, every pod sharing
the GPU would show the same values.

### 💾 Storage

**Only the model weights survive a rebuild.**
The weights live in a fixed folder (`/home/kind/storage/model-weights`) that the next cluster reuses.
Every other PVC, including Open WebUI's users and chats, gets a new `pvc-<uid>` folder per cluster,
so a teardown leaves that data behind.
→ *Workaround:* delete old `pvc-*` folders in `/home/kind/storage` by hand.

### 💬 Open WebUI

**Not production-ready yet.**
It runs as a single replica on a ReadWriteOnce PVC with SQLite, with no probes and no resource
limits. The open items are tracked in [`docs/todo.md`](docs/todo.md).
