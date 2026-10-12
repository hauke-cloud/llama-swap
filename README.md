<!-- llm-readme-management spec=1 commit=9ec18744f5a75605b1892432f1aa89b1b22fb542 template=helm model=qwen3.8-27b-q4 digest=5b6cfbe96d9f generated=2026-10-12T08:01:30Z -->
<a href="https://hauke.cloud" target="_blank"><img src="https://img.shields.io/badge/home-hauke.cloud-brightgreen" alt="hauke.cloud" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud" target="_blank"><img src="https://img.shields.io/badge/github-hauke.cloud-blue" alt="hauke.cloud Github Organisation" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud/llm-readme-management" target="_blank"><img src="https://img.shields.io/badge/template-helm-orange" alt="Repository type - helm" style="display: block;" /></a>


# Llama Swap


<img src="https://raw.githubusercontent.com/hauke-cloud/.github/main/resources/img/organisation-logo-small.png" alt="hauke.cloud logo" width="109" height="123" align="right">


<llm header hint="Name the chart and what it deploys.">

This Helm chart deploys the llama-swap proxy, an OpenAI-compatible gateway that starts, stops, and hot-swaps llama.cpp inference servers on demand so a single GPU node can serve many LLMs sequentially. It targets platform operators who install it onto a Kubernetes cluster to manage local model workloads.

</llm>


## :book: Description

<llm description>

You need to serve multiple large language models on a single GPU inside a Kubernetes cluster without dedicating separate hardware to each workload. This Helm chart deploys `mostlygeek/llama-swap`, an OpenAI-compatible proxy that runs in a single pod and hot-swaps local inference server processes on demand, managing model loading, unloading, and TTLs so one GPU serves many models sequentially behind a standard `/v1` API.

The chart renders all Kubernetes resources—Deployment, ConfigMap, Service, PVCs, and optional networking—so you configure models and macros in a values file rather than writing manifests by hand. It is published to `oci://ghcr.io/hauke-cloud/charts/llama-swap` under the `hauke-cloud` organisation.

- Single-replica Deployment (Recreate strategy) spawning inference servers as child processes in the pod.
- Renders upstream configuration (models, macros, TTLs, groups) into a ConfigMap or references an existing one.
- Optionally swaps in a combined image to run ComfyUI as a swappable workload on the same GPU.
- Exposes the proxy via Ingress or Gateway API HTTPRoute, with optional dedicated routes for ComfyUI.
- Provisions PVCs for model weights, state, and ComfyUI data.
- Optional Prometheus ServiceMonitor, alerts, Grafana dashboard, and per-model token-metrics sidecar.

</llm>


## :clipboard: Requirements

<llm requirements hint="Give the Kubernetes version constraint from Chart.yaml, the Helm version, and any dependency charts or CRDs that must already be present.">

- `kubectl` configured to communicate with your target Kubernetes cluster.
- Helm 3.4 or later, required for OCI registry support when installing from `oci://ghcr.io/hauke-cloud/charts/llama-swap`.
- A Kubernetes cluster that exposes the APIs you plan to use: `networking.k8s.io/v1` for Ingress, `gateway.networking.k8s.io/v1` for HTTPRoute. If you enable HTTPRoutes, the Gateway API CRDs and a Gateway resource matching your `httpRoute.parentRefs` must already be present.
- A GPU device plugin (NVIDIA, AMD ROCm, Intel, or MUSA) on the target nodes if you set `gpu.enabled: true`.
- GGUF model files on the models volume; the chart does not download them.
- *(Optional)* Prometheus Operator CRDs for `ServiceMonitor` and `PrometheusRule`; grafana-k8s-sidecar for the bundled Grafana dashboard.
- *(Contributors)* `pre-commit` and Python 3.

</llm>


## 🚀 Getting started

<llm getting_started hint="helm repo add, helm install and helm upgrade with the real repository URL and chart name. Show a values override only if the chart needs one to start.">

1. Clone the repository and enter its directory.
```bash
git clone https://github.com/hauke-cloud/llama-swap.git
cd llama-swap
```

2. Install the chart from the OCI registry to your Kubernetes cluster.
```bash
helm install llama-swap oci://ghcr.io/hauke-cloud/charts/llama-swap
```

3. Run the built-in test pod that spiders the `/health` endpoint.
```bash
helm test llama-swap
```

4. Port-forward the service and confirm the proxy responds.
```bash
kubectl port-forward svc/llama-swap 8080:8080
curl http://localhost:8080/health
```

The default install uses the CPU image and provisions an empty 100 Gi models volume; the proxy is up and answering health checks, but no model will load until you copy GGUF weights into the volume and reference them in `llamaSwap.config`.

</llm>


## :airplane: Usage

<llm usage hint="Show installing with a values file, and how to reach or verify the deployed workload.">

You install the chart from the OCI registry, supplying a values file that defines `llamaSwap.config` (or points to `llamaSwap.existingConfigMap`) along with any GPU or persistence overrides.

```bash
helm install llama-swap oci://ghcr.io/hauke-cloud/charts/llama-swap \
  --set image.tag=v243-cuda-b10133-non-root \
  --set gpu.enabled=true \
  --set gpu.resourceName=nvidia.com/gpu \
  --set persistence.models.existingClaim=model-library \
  --values my-models.yaml
```

Once the pod is running, you verify the deployment with the built-in test hook and by forwarding the ClusterIP service on port 8080:

```bash
helm test llama-swap
kubectl port-forward svc/llama-swap 8080:8080 &
curl http://localhost:8080/health
curl http://localhost:8080/v1/models
```

If you let the chart provision the models PVC (the default), you copy GGUF weights into the pod's `/models` volume before the proxy can serve them:

```bash
kubectl --namespace <ns> cp ./model.gguf \
  $(kubectl --namespace <ns> get pod -l app.kubernetes.io/instance=<release> -o name | head -1 | cut -d/ -f2):/models/model.gguf
```

</llm>


## :wrench: Configuration

<llm configuration hint="A table of the top-level values from values.yaml: key, default, description. Point at values.yaml for the full set.">

You configure the chart by passing values via `--set` or a custom YAML file. The table below lists the primary inputs; the full set lives in `charts/llama-swap/values.yaml`.

| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `llamaSwap.config` | object | `healthCheckTimeout: 500`, `logLevel: info`, `startPort: 10001`, one example model `qwen3-0.6b` | Yes (or set `existingConfigMap`) | Upstream llama-swap configuration (models, macros, TTLs, groups) rendered into a ConfigMap |
| `llamaSwap.existingConfigMap` | string | `""` | No | Name of an external ConfigMap that supplies the upstream config instead |
| `image.repository` | string | `ghcr.io/mostlygeek/llama-swap` | No | Container image repository |
| `image.tag` | string | `v243-cpu-b10133-non-root` | No (set explicitly for GPU) | Tag encoding release, backend (`cpu`, `cuda`, `rocm`, …), and llama.cpp build |
| `gpu.enabled` | bool | `false` | No | Requests GPU resources in the pod spec |
| `gpu.resourceName` | string | `nvidia.com/gpu` | Required when `gpu.enabled: true` | Kubernetes device-plugin resource name |
| `persistence.models.size` | string | `100Gi` | No | Size of the model-weights PVC (mounted at `/models`) |
| `comfyui.enabled` | bool | `false` | No | Swaps in the ComfyUI image and injects a ComfyUI model into the config |
| `ingress.enabled` | bool | `false` | No | Exposes the proxy through a classic `Ingress` |
| `httpRoute.enabled` | bool | `false` | No | Exposes the proxy through a Gateway API `HTTPRoute` |
| `env` / `envFrom` | list | `[]` | No | Environment variables and secret references (e.g. `apiKeys`) for the container |

Values for ComfyUI sub-options, metrics (ServiceMonitor, PrometheusRule, Grafana dashboard, token-exporter sidecar), pod security, scheduling, and extra volumes are also available in `values.yaml`.

</llm>


## 📄 License

This Project is licensed under the GNU General Public License v3.0

- see the [LICENSE](LICENSE) file for details.


## :coffee: Contributing

To become a contributor, please check out the [CONTRIBUTING](CONTRIBUTING.md) file.


## :email: Contact

For any inquiries or support requests, please open an issue in this
repository or contact us at [contact@hauke.cloud](mailto:contact@hauke.cloud).
