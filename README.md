

<a href="https://hauke.cloud" target="_blank"><img src="https://img.shields.io/badge/home-hauke.cloud-brightgreen" alt="hauke.cloud" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud" target="_blank"><img src="https://img.shields.io/badge/github-hauke.cloud-blue" alt="hauke.cloud Github Organisation" style="display: block;" /></a>
<a href="https://github.com/hauke-cloud/readme-management" target="_blank"><img src="https://img.shields.io/badge/template-helm-orange" alt="Repository type - helm" style="display: block;" /></a>


# llama-swap


<img src="https://raw.githubusercontent.com/hauke-cloud/.github/main/resources/img/organisation-logo-small.png" alt="hauke.cloud logo" width="109" height="123" align="right">


Helm chart to deploy llama-swap, an OpenAI-compatible proxy that loads and
hot-swaps local inference servers on demand.

(Upstream project: https://github.com/mostlygeek/llama-swap)

This chart offers you:
- Many models on a single GPU - llama-swap starts a model when it is requested and unloads it when idle
- OpenAI and Anthropic compatible endpoints, so existing clients work unchanged
- Any backend you can start with a command line: llama.cpp, vLLM, whisper.cpp, stable-diffusion.cpp
- CPU, CUDA, ROCm, Vulkan, Intel and MUSA image variants, running unprivileged by default
- Model weights from a provisioned volume, an existing claim or a host path
- Built-in web UI, Prometheus metrics and per-model idle timeouts




## 🚀 Getting started
To get started, you need to clone the repository. Follow the steps below:

### 1. Clone the repository

Use the following command to clone the repository:

```bash
git clone https://github.com/hauke-cloud/llama-swap.git
```

### 2. Navigate to the repository directory

Once the repository is cloned, navigate to the directory:

```bash
cd llama-swap
```

### 3. Check the content

```bash
ls -la
```

This will display all the files and directories in the cloned repository.



## :airplane: Usage
### Deploying the chart

Since we provide the chart in our public Github repository deploying it is
quite simple. You can run the following command to template and install the chart to your Kubernetes cluster:

#### Template the Helm chart

```bash
helm template oci://ghcr.io/hauke-cloud/charts/llama-swap
```

#### Deploy the Helm chart

```bash
helm install llama-swap oci://ghcr.io/hauke-cloud/charts/llama-swap
```

The defaults start a CPU build with an empty models volume, so the release comes
up on any cluster. Point it at real weights and a GPU before expecting tokens:

```bash
helm install llama-swap oci://ghcr.io/hauke-cloud/charts/llama-swap \
  --set image.tag=v243-cuda-b10133-non-root \
  --set gpu.enabled=true \
  --set persistence.models.existingClaim=model-library \
  --values my-models.yaml
```

### Configuration

All values, the model configuration format, GPU scheduling, model storage
options and API key handling are documented in the chart itself:

- [charts/llama-swap/README.md](charts/llama-swap/README.md)



## 📄 License

This Project is licensed under the GNU General Public License v3.0

- see the [LICENSE](LICENSE) file for details.


## :coffee: Contributing

To become a contributor, please check out the [CONTRIBUTING](CONTRIBUTING.md) file.


## :email: Contact

For any inquiries or support requests, please open an issue in this
repository or contact us at [contact@hauke.cloud](mailto:contact@hauke.cloud).
