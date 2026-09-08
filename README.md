<!-- llm-readme-management spec=1 commit=c85e9783caa9d15967b8893b4a036ea21853bb64 template=helm model=qwen3.6-35b-a3b digest=5b6cfbe96d9f generated=2026-09-08T21:14:46Z -->
<a href="https://hauke.cloud" target="_blank"><img src="https://img.shields.io/badge/home-hauke.cloud-brightgreen" alt="hauke.cloud" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud" target="_blank"><img src="https://img.shields.io/badge/github-hauke.cloud-blue" alt="hauke.cloud Github Organisation" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud/llm-readme-management" target="_blank"><img src="https://img.shields.io/badge/template-helm-orange" alt="Repository type - helm" style="display: block;" /></a>


# Llama Swap


<img src="https://raw.githubusercontent.com/hauke-cloud/.github/main/resources/img/organisation-logo-small.png" alt="hauke.cloud logo" width="109" height="123" align="right">


<llm header hint="Name the chart and what it deploys.">

This Helm chart deploys the llama-swap OpenAI-compatible proxy, enabling a single pod to hot-swap local inference backends on demand. You can use it to run LLM workloads on GPU nodes, optionally combining the proxy with ComfyUI image generation on shared hardware.

</llm>


## :book: Description

<llm description>

You need to serve multiple large language models on a single GPU within a Kubernetes cluster without dedicating separate hardware to each workload. This Helm chart deploys `mostlygeek/llama-swap`, an OpenAI-compatible proxy that runs inside a single pod and hot-swaps local inference server processes on demand. By managing model loading, unloading, and TTLs automatically, it allows one GPU to efficiently serve many models sequentially while maintaining a standard API interface.

The chart handles all Kubernetes resource generation, configuration mounting, and networking setup so you can focus on model selection rather than infrastructure plumbing. It also supports swapping between LLM inference and ComfyUI image generation on the same GPU when enabled.

- Renders a single-replica Deployment with llama-swap spawning backends as child processes inside its pod.
- Generates or accepts an existing ConfigMap for upstream configuration, including model macros and TTLs.
- Optionally integrates ComfyUI, registering it as a swappable workload that unloads the resident LLM when active.
- Exposes the proxy via Kubernetes Ingress or Gateway API HTTPRoutes, with optional dedicated hostnames for ComfyUI.
- Creates PersistentVolumeClaims for model storage, state databases, and ComfyUI data.

</llm>


## :clipboard: Requirements

<llm requirements hint="Give the Kubernetes version constraint from Chart.yaml, the Helm version, and any dependency charts or CRDs that must already be present.">

Before deploying this chart, ensure you have the following installed and configured:
- `kubectl` configured to communicate with your target Kubernetes cluster.
- Helm 3.4+ for OCI registry support during installation and upgrades.
- A Kubernetes cluster running v1.19+ (for standard Ingress) or v1.26+ (for Gateway API HTTPRoute). If using HTTPRoute, you must also install the corresponding Gateway API CRDs.
- A GPU device plugin on your worker nodes if you enable `gpu.enabled`. This requires the appropriate drivers and kubelet plugins for NVIDIA, AMD ROCm, Intel oneAPI, or MUSA.
- An OCI registry token to pull container images from `ghcr.io`.

</llm>


## 🚀 Getting started

<llm getting_started hint="helm repo add, helm install and helm upgrade with the real repository URL and chart name. Show a values override only if the chart needs one to start.">

1. Clone the repository and enter its directory.
```bash
git clone https://github.com/hauke-cloud/llama-swap.git
cd llama-swap
```
2. Deploy the chart to your Kubernetes cluster using Helm.
```bash
helm install llama-swap oci://ghcr.io/hauke-cloud/charts/llama-swap
```

</llm>


## :airplane: Usage

<llm usage hint="Show installing with a values file, and how to reach or verify the deployed workload.">

To consume this chart in your own project, you install it directly from the OCI registry while supplying a values file and explicit GPU configuration. The chart requires either `llamaSwap.config` or `llamaSwap.existingConfigMap`, so your values file must define one of these before installation.

```bash
helm install llama-swap oci://ghcr.io/hauke-cloud/charts/llama-swap \
  --set image.tag=v243-cuda-b10133-non-root \
  --set gpu.enabled=true \
  --set gpu.resourceName=nvidia.com/gpu \
  --set persistence.models.existingClaim=model-library \
  --values my-models.yaml
```

After deployment, you verify the workload and reach the proxy by forwarding the ClusterIP service on port 8080. You can also run the built-in test hook to confirm the health endpoint responds correctly.

```bash
kubectl port-forward svc/llama-swap 8080:8080 &
curl http://localhost:8080/health
helm test llama-swap
```

</llm>


## :wrench: Configuration

<llm configuration hint="A table of the top-level values from values.yaml: key, default, description. Point at values.yaml for the full set.">

You configure the chart by passing values via `--set` or a custom YAML file. The following table lists the primary inputs that control deployment behavior, resource allocation, and model serving:

| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `llamaSwap.config` | object | healthCheckTimeout 500, one example model `qwen3-0.6b` | Yes (or use `existingConfigMap`) | Upstream llama-swap configuration map |
| `llamaSwap.existingConfigMap` | string | `""` | No | Name of an existing ConfigMap containing the upstream config |
| `image.tag` | string | `"v243-cpu-b10133-non-root"` | Yes (explicit for GPU) | Container image tag; must be set explicitly for GPU builds |
| `gpu.enabled` | bool | `false` | No | Enables GPU resource allocation |
| `gpu.resourceName` | string | `"nvidia.com/gpu"` | Required when `gpu.enabled: true` | Kubernetes device plugin resource name |
| `persistence.models.enabled` | bool | `true` | No | Creates a PVC for model storage |
| `persistence.models.size` | string | `"100Gi"` | No | Size of the model storage PVC |
| `comfyui.enabled` | bool | `false` | No | Enables ComfyUI integration and image swap |
| `serviceAccount.create` | bool | `true` | No | Creates a dedicated ServiceAccount for the pod |

The chart exposes many additional values for ingress, HTTPRoute, ComfyUI sub-options, and pod security. You can find the complete configuration surface in `values.yaml`.

</llm>


## 📄 License

This Project is licensed under the GNU General Public License v3.0

- see the [LICENSE](LICENSE) file for details.


## :coffee: Contributing

To become a contributor, please check out the [CONTRIBUTING](CONTRIBUTING.md) file.


## :email: Contact

For any inquiries or support requests, please open an issue in this
repository or contact us at [contact@hauke.cloud](mailto:contact@hauke.cloud).
