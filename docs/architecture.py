"""High-level system diagram for the README, drawn with https://github.com/mingrammer/diagrams.

Needs Graphviz (`sudo apt install graphviz`). Regenerate docs/architecture.png with:

    uv run --no-project --with diagrams python docs/architecture.py
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.k8s.compute import Deploy, Job
from diagrams.k8s.storage import PVC
from diagrams.onprem.client import Users
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.network import Internet, Traefik

OUT = Path(__file__).with_name("architecture")   # Diagram appends .png

# Fira Sans if installed; Graphviz falls back to its default sans font otherwise.
FONT = "Fira Sans"
TEXT, MUTED = "#0F172A", "#475569"

graph_attr = {
    "fontname": f"{FONT} SemiBold", "fontsize": "22", "fontcolor": TEXT,
    "bgcolor": "white", "pad": "0.6", "nodesep": "0.8", "ranksep": "1.3",
    # Curved edges: the default orthogonal routing ends arrows next to, not at, the icons.
    "splines": "spline",
}
node_attr = {"fontname": FONT, "fontsize": "13", "fontcolor": MUTED}
edge_attr = {"fontname": FONT, "fontsize": "11", "fontcolor": MUTED, "penwidth": "1.6", "arrowsize": "0.7"}


def zone(fill, border):
    """Tinted, rounded cluster with a left-aligned label (Tailwind-style 50/200 shades)."""
    return {"bgcolor": fill, "pencolor": border, "penwidth": "1.5", "style": "rounded",
            "fontname": f"{FONT} SemiBold", "fontsize": "14", "fontcolor": TEXT,
            "labeljust": "l", "margin": "24"}


def flow(color, **kw):
    return Edge(color=color, **kw)


REQUEST, MODEL, METRICS = "#6366F1", "#10B981", "#F59E0B"

with Diagram("vllm-k8s", filename=str(OUT), show=False, direction="LR",
             graph_attr=graph_attr, node_attr=node_attr, edge_attr=edge_attr):
    users = Users("API clients\n& browser")
    hf = Internet("Hugging Face Hub")

    with Cluster("Host  ·  kind cluster (2 Docker containers)", graph_attr=zone("#F8FAFC", "#E2E8F0")):
        with Cluster("CPU node  ·  workload=cpu", graph_attr=zone("#EEF2FF", "#C7D2FE")):
            ingress = Traefik("traefik\n127.0.0.1:8080")
            gateway = Deploy("LiteLLM\ngateway")
            with Cluster("Observability", graph_attr=zone("#FFF7ED", "#FED7AA")):
                prometheus = Prometheus("Prometheus")
                grafana = Grafana("Grafana\ndashboards")

        with Cluster("GPU node  ·  workload=gpu-decoder (tainted)", graph_attr=zone("#ECFDF5", "#A7F3D0")):
            # Pods that request nvidia.com/gpu. GPU Operator daemons (device plugin, DCGM exporter) are
            # cluster plumbing and left out; see the README's component table.
            with Cluster("GPU consumers  ·  nvidia.com/gpu", graph_attr=zone("#D1FAE5", "#34D399")):
                vllm = Deploy("vLLM")
            download = Job("model download")
            weights = PVC("model weights")

    users >> flow(REQUEST, label="OpenAI API") >> ingress
    ingress >> flow(REQUEST) >> gateway >> flow(REQUEST) >> vllm
    users >> flow(REQUEST, label="grafana.localhost") >> ingress
    ingress >> flow(REQUEST) >> grafana

    hf >> flow(MODEL, label="weights") >> download >> flow(MODEL) >> weights >> flow(MODEL) >> vllm

    # `<<` keeps the arrow on Prometheus but ranks it before the GPU node, so the layout stays left-to-right.
    prometheus << flow(METRICS, style="dashed", label="metrics") << vllm
    grafana >> flow(METRICS) >> prometheus
