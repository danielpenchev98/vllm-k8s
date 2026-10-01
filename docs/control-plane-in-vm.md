# Checkpoint: move the k3s control plane into the VM

Goal: the multipass VM runs the k3s **server** (control plane) and all non-GPU workloads.
The host (`pop-os`, RTX 3090) becomes a k3s **agent** that runs only GPU workloads plus the
per-node system pods (GPU Operator daemonsets, NFD worker, optionally svclb).

```
before                                   after
pop-os   : server + GPU + system pods    k3s-server (VM): control plane, coredns, traefik,
k3s-agent: CPU workloads                                  metrics-server, local-path, LiteLLM, …
                                         pop-os (host)  : agent, vLLM, GPU Operator daemonsets
```

Work top to bottom; tick boxes as you go. Each step ends with a **Check**.

---

## Known issues found before starting

- [ ] **Bind mount vs uninstall.** `/var/lib/rancher/k3s` is bind-mounted from `/home/k3s`
      (`/etc/fstab`). `k3s-uninstall.sh` runs `rm -rf /var/lib/rancher/k3s`, which deletes the
      *contents of `/home/k3s`* (including the model PVC folder) and may leave the mount missing,
      so the next install would write to the small root partition again.
- [ ] **VM disk lives on root.** Root has ~12 GB free; multipass stores VM disks under
      `/var/snap/multipass`. A 40 GB server VM would fill it.
- [ ] **svclb won't run on a tainted host.** `svclb-traefik` only tolerates `control-plane` and
      `CriticalAddonsOnly`. Today's pod on `pop-os` predates the taint. After the rebuild the
      Ingress is served only on the VM IP (`10.122.104.x`, behind NAT) → no LAN access via
      `192.168.0.106` unless you pick a fix in step 0.

---

## Step 0 — Decisions and prep

- [ ] **Model weights:** copy `/home/k3s/storage/pvc-*_llm_model-weights/qwen3-4b` somewhere safe,
      or accept a 7.5 GB re-download (`deploy/deploy.sh` does it anyway).
- [ ] **Multipass storage off root:** follow the multipass docs page on configuring where
      multipass stores its data (`MULTIPASS_STORAGE` via a systemd override for the snap).
      Check which paths the snap is allowed to use.
- [ ] **LAN entry point** — pick one:
  - (a) Let svclb run on the GPU node (it's one of the "system pods" you accept there).
        Look up in the k3s ServiceLB docs how to give svclb pods extra tolerations
        (a `svccontroller.k3s.cattle.io/…` annotation on the Service; for traefik, set it via a
        `HelmChartConfig`). **Verify the exact annotation for your k3s version.**
  - (b) Put the VM on the LAN with multipass bridged networking (`--network enp12s0`), so
        traefik on the VM has a LAN IP.
  - (c) Accept host-only access through the VM IP.

**Check:** decisions written down in `docs/journal.md`; `df -h /` has room for what stays on root.

---

## Step 1 — Tear down the current cluster

```bash
./infra/local/teardown-infra.sh              # agent VM + GPU Operator bits
sudo /usr/local/bin/k3s-uninstall.sh         # host k3s server
findmnt /var/lib/rancher/k3s                 # must still show /home/k3s
sudo mount /var/lib/rancher/k3s              # only if the line above printed nothing
```

**Check:** `df -h /var/lib/rancher/k3s` reports the `/home` partition — **before** installing
anything on the host again. `multipass list` shows no leftover VMs (`multipass purge`).

---

## Step 2 — Control plane in the VM

```bash
multipass launch 24.04 --name k3s-server --cpus 4 --memory 12G --disk 40G
VM_IP=$(multipass info k3s-server --format json | jq -r '.info["k3s-server"].ipv4[0]')
multipass exec k3s-server -- bash -c "curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.36.4+k3s1 sh -s - server \
  --node-label workload=cpu --tls-san $VM_IP"
```

- `--node-label workload=cpu` — labelled from the moment it registers.
- `--tls-san $VM_IP` — API server certificate valid for the IP the host will use
  (otherwise: x509 errors from `kubectl`).

Kubeconfig on the host:

```bash
multipass exec k3s-server -- sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127.0.0.1/$VM_IP/" > ~/.kube/config
chmod 600 ~/.kube/config
```

**Check:** `kubectl get nodes` → one node, `k3s-server`, role `control-plane`, label `workload=cpu`.

Know: host `kubectl` now depends on the VM being up. The VM IP comes from multipass DHCP;
normally stable, but if it changes both the kubeconfig and the agent's server URL break.

---

## Step 3 — Join the host as the GPU agent

```bash
TOKEN=$(multipass exec k3s-server -- sudo cat /var/lib/rancher/k3s/server/node-token)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.4+k3s1 \
  K3S_URL=https://$VM_IP:6443 K3S_TOKEN=$TOKEN sh -s - agent \
  --node-label workload=gpu-decoder \
  --node-taint workload=gpu-decoder:NoSchedule
```

- Label + taint **at registration**: nothing non-GPU can land on the host before the taint exists
  (last time coredns/traefik got there first).
- Host service is now **`k3s-agent`** (uninstall: `k3s-agent-uninstall.sh`).

Firewall (ufw) on the host — it's a worker now:

| Port | Keep? | Why |
|---|---|---|
| `8472/udp` | yes | flannel VXLAN between nodes |
| `10250/tcp` | yes | kubelet (metrics-server, logs/exec) |
| pod/service CIDRs | yes | `10.42.0.0/16`, `10.43.0.0/16` |
| `6443/tcp` | no | API server lives in the VM now |
| `80/443/tcp` | only with option 0(a) | svclb on the host |

**Check:**

```bash
sudo grep nvidia-container-runtime /var/lib/rancher/k3s/agent/etc/containerd/config.toml
kubectl get runtimeclass nvidia
kubectl get nodes -o wide --show-labels | grep workload
kubectl describe node pop-os | grep Taints
```

If the nvidia runtime is missing: `sudo systemctl restart k3s-agent` (it's detected at startup).

---

## Step 4 — GPU Operator + test pod

Same command and `infra/local/gpu-operator-values.yaml` as before. What changes is placement:

- operator Deployment, NFD master/gc → **VM** (they prefer the control-plane node)
- device plugin, DCGM exporter, validators, feature discovery → **host** (via the
  `workload=gpu-decoder` toleration in the values file)

**Check:**

```bash
kubectl get node pop-os -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'   # → 1
kubectl get node pop-os --show-labels | tr ',' '\n' | grep nvidia.com/gpu.product
```

Then run the `nvidia-smi` test pod (nodeSelector + toleration + `runtimeClassName: nvidia`).

---

## Step 5 — Deploy the stack and verify placement

```bash
deploy/deploy.sh
kubectl get pods -A -o wide --field-selector spec.nodeName=pop-os
kubectl get pods -A -o wide --field-selector spec.nodeName=k3s-server
```

Expected on **pop-os**: `vllm`, GPU Operator daemonsets, `nfd-worker`, `svclb-*` (option a only),
the model-download Job while it runs. Everything else on **k3s-server**.

**Phase 2 gate:** an unlabelled pod lands on the VM:

```bash
kubectl run gate --image=nginx --restart=Never && kubectl get pod gate -o wide && kubectl delete pod gate
```

**Check:** chat completion through the Ingress works from where you decided in step 0;
direct vLLM access from another pod is still refused (NetworkPolicy).

---

## Step 6 — Update the scripts so it's reproducible

| File | Change |
|---|---|
| `infra/local/common.sh` | `gpu_node()` selects `node-role.kubernetes.io/control-plane` — that's the VM now; select `workload=gpu-decoder`. Rename `AGENT_NAME` → e.g. `SERVER_NAME`. Move `K3S_VERSION` here. |
| `infra/local/install-deps.sh` | Remove `install_k3s` + kubeconfig copy. Add `install_multipass` to `main`. Drop `k3s --version` / `kubectl get nodes` from `verify`. |
| `infra/local/setup-infra.sh` | New order: launch VM → server install → kubeconfig → host firewall → join host as agent (label + taint) → check runtime (restart `k3s-agent`, not `k3s`) → GPU Operator → test pod. `label_gpu_node` becomes a harmless double check. |
| `infra/local/teardown-infra.sh` | Cluster lives in the VM: delete VM + `k3s-agent-uninstall.sh` on host + ufw rules. Operator/CRD cleanup is no longer needed. Add the bind-mount check from step 1. |
| `deploy/` | Nothing — proof the manifests are topology-independent. |

**Check (the real gate):** from scratch, `teardown-infra.sh` → `setup-infra.sh` →
`deploy/deploy.sh` brings the endpoint back with no manual steps.

---

## New operational facts

- Boot order matters: the VM must be up before the cluster works; the host agent retries until
  the server is reachable. Confirm the VM comes back after a host reboot.
- The VM now carries control plane + LiteLLM + (later) Prometheus + benchmark client.
  Watch `kubectl top node k3s-server` during sweeps; if it saturates, results measure the VM.

## Journal entries to write

- Why the control plane moved (principle: non-GPU work off the GPU node; EKS-like layout).
- svclb tolerations and the LAN-access decision.
- Bind mount wiped by `k3s-uninstall.sh` (if it happened) and how you guarded against it.
- Before/after: k3s server CPU on the host during a load test.
