# llama-swap

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v243](https://img.shields.io/badge/AppVersion-v243-informational?style=flat-square)

Helm chart for [mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap) — an
OpenAI-compatible proxy that starts, stops and hot-swaps `llama-server` (and other
inference) processes on demand, so a single GPU can serve many models.

The proxy is one process that spawns the inference servers as child processes in the
same container. That shapes the whole chart: it is a single-replica `Deployment` with a
`Recreate` strategy, a config file in a ConfigMap, and a volume holding the model
weights. There is no HPA — scaling out means every replica loads its own copy of a
model and occupies its own GPU, which is a decision to make deliberately, not
automatically.

## Installation

```sh
helm install llama-swap oci://ghcr.io/hauke-cloud/charts/llama-swap
```

The defaults come up on any cluster: a CPU image, an empty 100Gi models volume and one
example model. Nothing will actually infer until model files exist on that volume and
`llamaSwap.config` points at them.

## Model storage

The container reads GGUF files from the volume mounted at
`persistence.models.mountPath` (`/models`). Pick whichever of these fits:

- **Existing claim** — the usual production setup. Fill a PVC out of band (a copy job,
  an NFS/CephFS export, a snapshot) and reference it:

  ```yaml
  persistence:
    models:
      existingClaim: model-library
      readOnly: true
  ```

  `ReadWriteMany` lets you top the volume up while llama-swap keeps serving.

- **Chart-provisioned claim** — the default. An empty PVC is created and annotated
  `helm.sh/resource-policy: keep`, so `helm uninstall` does not throw the weights away.
  Set `persistence.models.retain=false` if you would rather it be deleted with the
  release.

- **Host path** — for a single GPU node that already has the models on local NVMe:

  ```yaml
  persistence:
    models:
      hostPath: /mnt/nvme/models
  nodeSelector:
    kubernetes.io/hostname: gpu-01
  ```

  Pin the pod to that node, or it will schedule somewhere without the files.

## GPU

Requesting a device needs three things to agree: a GPU image variant, the extended
resource, and scheduling onto the right node.

```yaml
image:
  tag: v243-cuda-b10133-non-root
gpu:
  enabled: true
  resourceName: nvidia.com/gpu
  count: 1
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

`gpu.count` is added to `resources.limits`; Kubernetes derives the matching request.
Upstream publishes `cuda`, `cuda13`, `rocm`, `vulkan`, `intel` and `musa` builds — see
[image.tag](#values) for the tag scheme. Multi-GPU setups that move tensors through
shared memory usually also want `shm.enabled=true`, because the container default of
64Mi for `/dev/shm` is too small.

## Configuration

`llamaSwap.config` is the [upstream config
format](https://github.com/mostlygeek/llama-swap/blob/main/config.example.yaml)
verbatim, rendered into a ConfigMap. Anything llama-swap accepts — `macros`, `groups`,
`hooks`, `selectors`, `peers`, `filters` — goes in as-is:

```yaml
llamaSwap:
  config:
    healthCheckTimeout: 500
    macros:
      "llama-server": "llama-server --host 127.0.0.1 --port ${PORT}"
    models:
      "qwen3-30b":
        cmd: |
          ${llama-server}
          --model /models/Qwen3-30B-A3B-Q4_K_M.gguf
          --ctx-size 32768
          --n-gpu-layers 99
        ttl: 600
```

Bring your own ConfigMap instead with `llamaSwap.existingConfigMap`.

The ConfigMap is mounted as a directory rather than a `subPath`, so kubelet propagates
edits into the running container. By default the pod carries a checksum annotation and
restarts when the config changes; set `llamaSwap.watchConfig=true` to have llama-swap
reload the file in place instead — the chart then drops the annotation so the pod
survives the change.

### Secrets

Keep API keys out of the ConfigMap. llama-swap expands `${env.NAME}` anywhere in the
config, so reference them and inject the values from a Secret:

```yaml
llamaSwap:
  config:
    apiKeys:
      - ${env.LLAMA_SWAP_API_KEY}
envFrom:
  - secretRef:
      name: llama-swap-apikeys
```

`/health` is deliberately exempt from API key checks upstream, so the probes keep
working once `apiKeys` is set.

## Exposing the service

Endpoints on the service port: `/v1/*` (OpenAI), `/v1/messages` (Anthropic), `/ui` (web
interface), `/running`, `/metrics`, `/health`.

Ingress is off by default. When enabling it, raise the proxy timeouts — a cold model
load can take minutes before the first token arrives, and streaming responses hold the
connection open:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
  hosts:
    - host: llm.example.com
      paths:
        - path: /
          pathType: Prefix
```

Note that anything reachable through that Ingress can run inference on your GPU unless
you configure `apiKeys`.

## Probes and slow starts

All three probes hit `/health`, which the proxy answers as soon as it is listening —
model loading happens lazily per request and does not affect readiness. The exception is
`hooks.on_startup.preload`: the proxy loads those models before serving, so the startup
probe allows 5 minutes by default. Raise `startupProbe.failureThreshold` if you preload
something large from slow storage.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules for pod scheduling. |
| env | list | `[]` | Environment variables for the container (list of name/value or name/valueFrom). Referenced from the config as `${env.NAME}`. |
| envFrom | list | `[]` | Additional envFrom sources, e.g. a Secret holding API keys. |
| extraVolumeMounts | list | `[]` | Additional volumeMounts on the container. |
| extraVolumes | list | `[]` | Additional volumes on the pod. |
| fullnameOverride | string | `""` | Override the full generated resource name. |
| gpu.count | int | `1` | Number of devices to request. Added to resources.limits. |
| gpu.enabled | bool | `false` | Request a GPU for the pod. Requires a matching device plugin and a GPU image variant (see image.tag). |
| gpu.resourceName | string | `"nvidia.com/gpu"` | Extended resource name, e.g. nvidia.com/gpu, amd.com/gpu, gpu.intel.com/i915. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/mostlygeek/llama-swap"` | llama-swap image repository. |
| image.tag | string | `"v243-cpu-b10133-non-root"` | Image tag, pinning the llama-swap release, the backend and the llama.cpp build. |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| ingress.annotations | object | `{}` | Annotations for the Ingress. |
| ingress.className | string | `""` | IngressClass name. |
| ingress.enabled | bool | `false` | Expose llama-swap through an Ingress. |
| ingress.hosts | list | `[{"host":"llama-swap.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress host rules. |
| ingress.tls | list | `[]` | TLS configuration. |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/health","port":"http"},"periodSeconds":20,"timeoutSeconds":5}` | Liveness probe. |
| llamaSwap.command | list | `[]` | Override the container command. Empty uses the chart's own invocation of the `llama-swap` binary (the image entrypoint hardcodes /app/config.yaml). |
| llamaSwap.config | object | `{"healthCheckTimeout":500,"logLevel":"info","macros":{"llama-server":"llama-server --host 127.0.0.1 --port ${PORT}\n"},"models":{"qwen3-0.6b":{"aliases":["gpt-3.5-turbo"],"cmd":"${llama-server}\n--model /models/Qwen3-0.6B-Q4_K_M.gguf\n--ctx-size 8192\n","ttl":300}},"startPort":10001}` | llama-swap configuration, rendered into a ConfigMap as config.yaml. |
| llamaSwap.configKey | string | `"config.yaml"` | File name of the config within that directory. |
| llamaSwap.configMountPath | string | `"/etc/llama-swap"` | Directory the config file is mounted into. |
| llamaSwap.existingConfigMap | string | `""` | Use an existing ConfigMap holding the config file instead of rendering `llamaSwap.config`. It must contain a key matching `llamaSwap.configKey`. |
| llamaSwap.extraArgs | list | `[]` | Extra command line arguments for llama-swap. |
| llamaSwap.port | int | `8080` | Port llama-swap listens on inside the container. |
| llamaSwap.watchConfig | bool | `false` | Reload the configuration when the file changes (`--watch-config`). |
| nameOverride | string | `""` | Override the chart name portion of resource names. |
| nodeSelector | object | `{}` | Node selector for pod scheduling. |
| persistence.data.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.data.annotations | object | `{}` | Annotations for the PVC. |
| persistence.data.enabled | bool | `false` | Persist llama-swap's state database (activity log and metrics history). |
| persistence.data.existingClaim | string | `""` | Use an existing PVC instead of provisioning one. |
| persistence.data.mountPath | string | `"/data"` | Where the state volume is mounted. |
| persistence.data.retain | bool | `true` | Keep the PVC when the release is uninstalled. |
| persistence.data.size | string | `"1Gi"` | Volume size. |
| persistence.data.storageClass | string | `""` | StorageClass. Empty uses the cluster default; "-" disables dynamic provisioning. |
| persistence.models.accessModes | list | `["ReadWriteOnce"]` | Access modes. ReadWriteMany lets other pods top the volume up while llama-swap runs, if the backend supports it. |
| persistence.models.annotations | object | `{}` | Annotations for the PVC. |
| persistence.models.enabled | bool | `true` | Mount a volume holding the model files. Without it the container has nowhere to read GGUFs from. |
| persistence.models.existingClaim | string | `""` | Use an existing (usually prepopulated) PVC instead of provisioning a new, empty one. Mutually exclusive with hostPath. |
| persistence.models.hostPath | string | `""` | Use a host directory instead of a PVC. Mutually exclusive with existingClaim. |
| persistence.models.mountPath | string | `"/models"` | Where the models volume is mounted. |
| persistence.models.readOnly | bool | `false` | Mount the models read-only. |
| persistence.models.retain | bool | `true` | Keep the PVC when the release is uninstalled. |
| persistence.models.size | string | `"100Gi"` | Volume size. Model weights are large; size for what you plan to host. |
| persistence.models.storageClass | string | `""` | StorageClass. Empty uses the cluster default; "-" disables dynamic provisioning. |
| podAnnotations | object | `{}` | Annotations to add to the pod. |
| podLabels | object | `{}` | Labels to add to the pod. |
| podSecurityContext | object | `{"fsGroup":10001,"fsGroupChangePolicy":"OnRootMismatch"}` | Pod-level security context. fsGroup makes the mounted volumes writable by the unprivileged user of the `-non-root` images. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/health","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe. |
| replicaCount | int | `1` | Number of replicas. llama-swap starts and stops inference processes inside its own pod, so every replica loads its own copy of a model and holds its own GPU. Keep this at 1 unless each replica has a dedicated GPU and model volume. |
| resources | object | `{}` | Resource requests and limits. |
| runtimeClassName | string | `""` | RuntimeClass for the pod, e.g. "nvidia" on clusters that need it. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":false,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Container-level security context. |
| service.annotations | object | `{}` | Annotations to add to the Service. |
| service.port | int | `8080` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Annotations to add to the ServiceAccount. |
| serviceAccount.automount | bool | `false` | Automatically mount the ServiceAccount's API token. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount for the pod. |
| serviceAccount.name | string | `""` | Name of the ServiceAccount. Generated if empty and create is true. |
| shm.enabled | bool | `false` | Replace the default 64Mi /dev/shm with a larger tmpfs. |
| shm.sizeLimit | string | `"1Gi"` | Size of the /dev/shm tmpfs. Counts against the container's memory limit. |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/health","port":"http"},"periodSeconds":5,"timeoutSeconds":5}` | Startup probe. |
| strategy | object | `{"type":"Recreate"}` | Deployment update strategy. |
| terminationGracePeriodSeconds | int | `120` | Grace period on shutdown. |
| tmpSizeLimit | string | `"1Gi"` | Size limit of the emptyDir mounted at /tmp. |
| tolerations | list | `[]` | Tolerations for pod scheduling. GPU nodes are commonly tainted. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Hauke Mettendorf | <hauke@mettendorf.it> |  |

## Source Code

* <https://github.com/mostlygeek/llama-swap>
* <https://github.com/hauke-cloud/llama-swap>
