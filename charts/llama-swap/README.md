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

## ComfyUI

`comfyui.enabled` switches the deployment to
[hauke-cloud/llama-swap-comfyui](https://github.com/hauke-cloud/llama-swap-comfyui) —
the upstream CUDA images with ComfyUI installed alongside llama-swap — and registers
ComfyUI as a swappable model:

```yaml
comfyui:
  enabled: true
gpu:
  enabled: true
```

ComfyUI is then reached through llama-swap's own port at `/comfyui/`, so it needs no
Service or second port of its own. Opening that path starts it the same way an
inference request starts an LLM, and it stops again after `comfyui.ttl` seconds idle.
That is the entire point of running it here rather than beside llama-swap: **one GPU,
one workload at a time** — loading ComfyUI unloads the resident LLM and vice versa.

That short path is not a generic proxy route. llama-swap v249 added first-class
handling for one exact model id, `comfyui_auto`, which is what `comfyui.name` defaults
to: it is served at `/comfyui/`, its concurrency limit is raised to 50, and websockets
stop counting towards model lifecycle. The last one is the important one — ComfyUI
holds a progress websocket open for as long as a browser tab is, and without it that
idle tab reads as activity, so the TTL never fires and the LLM never gets its GPU back.
Rename the model and the chart falls back to `/upstream/<name>/`, setting
`concurrencyLimit` and `compat.ignoreWebsockets` on the entry by hand so the behaviour
survives the rename.

`comfyui.image` replaces `image` when the feature is on; the two repositories have
different tags. Only CUDA backends are published, because ComfyUI needs a PyTorch
accelerator. The default `cuda-non-root` is a floating tag (CUDA 12.8, torch `cu128`) —
upstream prunes old tags, so pinning a build in chart defaults would rot. Pin one
yourself for reproducible rollouts. Blackwell cards (sm_120) need the `cuda13` line.

### Groups

Models that are not in a group belong to llama-swap's default group, which is
exclusive — so with no `groups` in the config, the swapping above happens on its own.
As soon as the config defines its own groups, it stops: ComfyUI stays in the default
group and will happily run beside a group member, both claiming the same GPU. Name the
group and the chart adds ComfyUI to its members:

```yaml
comfyui:
  enabled: true
  group: gpu
llamaSwap:
  config:
    groups:
      gpu:
        swap: true
        exclusive: true
        members:
          - qwen3-coder
          - gpt-oss
```

### Its own hostname

`comfyui.ingress` adds a second Ingress, pointing at the same Service, that serves
ComfyUI from the root of a hostname of its own:

```yaml
comfyui:
  enabled: true
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-body-size: "0"
    hosts:
      - host: comfy.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts: [comfy.example.com]
        secretName: comfy-tls
```

The backend still serves ComfyUI under a prefix, so the Ingress has to put it back on:
`comfyui.ingress.rewrite` (on by default) emits ingress-nginx's `rewrite-target` and
`use-regex` annotations and turns each path into the regex they need — `/` becomes
`/()(.*)`, `/comfy` becomes `/comfy(/|$)(.*)`, and both feed the same `$2` target, so
one Ingress can carry several paths. `pathType` is `ImplementationSpecific` in that
mode. ComfyUI derives its API base from the page URL, so the UI, `/api` and the
websocket all follow the rewrite without further configuration.

On another controller set `rewrite: false` and either point `path` at `/comfyui`
directly, or do the rewrite in your own way — a Traefik middleware, an annotation your
controller understands. Leaving `rewrite: false` with `path: /` publishes all of
llama-swap on that hostname, API and UI included; `helm install` prints a warning when
it detects that.

`comfyui.httpRoute` is the Gateway API version of the same thing, and there the rewrite
is a first-class `URLRewrite` filter rather than an annotation:

```yaml
comfyui:
  enabled: true
  httpRoute:
    enabled: true
    parentRefs:
      - name: hauke-cloud
        namespace: envoy-gateway
    hostnames:
      - comfy.example.com
```

`rewrite: true` (the default) turns each entry in `paths` into a rule that rewrites onto
ComfyUI's prefix, derived from `comfyui.name`, and adds one more rule publishing that
prefix unrewritten. Both are needed. Envoy rewrites by swapping the matched prefix for
the replacement as a plain string, so the host root arrives as `/comfyui`, llama-swap
answers `301 /comfyui/`, and without the second rule the redirect comes back through the
rewrite and is glued into `/comfyuicomfyui/` — a 404. The unrewritten rule is the longer
path match, so it takes precedence and serves the redirect target and every relative
asset under it. Set `replacePrefixMatch` to override the prefix; a trailing slash on it
is dropped, because Envoy Gateway trims one anyway. TLS belongs to the Gateway's
listener, so there is no `tls` block here.

Both routes front the same process, so `apiKeys` guards this hostname too:
`/comfyui/` runs through the same auth middleware as `/v1`. llama-swap answers a
missing key with `WWW-Authenticate: Basic`, so a browser prompts and any username with
the API key as the password gets in. Without `apiKeys`, anyone who can reach the host
can queue work on your GPU.

### Storage

`/data/comfyui` is passed to ComfyUI as `--base-directory`, so checkpoints, LoRAs,
custom nodes, inputs, outputs and user settings all sit on the one volume that
`persistence.comfyui` provisions (50Gi by default, `helm.sh/resource-policy: keep`).
Point it at an existing claim or a host path the same way as the models volume. Custom
nodes must be installed into it rather than baked into the image, or an image update
loses them.

The volume has to be writable by the container user. The chart's default `fsGroup:
10001` handles that; if you clear `podSecurityContext` — a reasonable thing to do when
the models volume is large enough that a recursive chown on every start hurts — make
sure the ComfyUI volume is writable by uid 10001 some other way.

### Config

The ComfyUI model entry is generated from the `comfyui.*` values and merged into
`llamaSwap.config`. An entry you write yourself under `comfyui.name` is never
overwritten, `comfyui.extraArgs` appends flags, and `comfyui.cmd` replaces the command
outright. With `llamaSwap.existingConfigMap` there is nothing to merge into: set
`comfyui.injectModel=false` and carry the entry in your own ConfigMap.

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

### Gateway API

`httpRoute` is the same thing for a cluster running an API gateway rather than an Ingress
controller. It attaches to a Gateway that already terminates TLS, so there is no `tls`
block and no controller-specific annotations — the timeouts are part of the route:

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: hauke-cloud
      namespace: envoy-gateway
  hostnames:
    - llm.example.com
  timeouts:
    request: 0s
    backendRequest: 0s
```

`0s` disables the timeout; without it Envoy cuts the request off after 15 seconds, long
before a cold model has loaded. A cross-namespace `parentRefs` entry only attaches if
that Gateway's listener allows routes from this namespace.

`rules` is there for anything the generated rule does not cover. Each entry is a Gateway
API rule, and one without `backendRefs` is pointed at this chart's Service:

```yaml
httpRoute:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
```

`ingress` and `httpRoute` are independent, so both can be enabled while a cluster
migrates from one to the other.

## Probes and slow starts

All three probes hit `/health`, which the proxy answers as soon as it is listening —
model loading happens lazily per request and does not affect readiness. The exception is
`hooks.on_startup.preload`: the proxy loads those models before serving, so the startup
probe allows 5 minutes by default. Raise `startupProbe.failureThreshold` if you preload
something large from slow storage.

## Monitoring

llama-swap exposes its performance metrics (CPU, RAM, network, GPU) at `/metrics`
in Prometheus format, on the same port as the API. Two values wire it into a
Prometheus Operator cluster:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus
  prometheusRule:
    enabled: true
```

The ServiceMonitor needs labels your Prometheus instance selects on —
`release: prometheus` is the common case — and a `namespace` pointing at the one
your instance watches, if that is not the release namespace. The default alert
rules (`up`, GPU memory, GPU temperature) match on the `service` label the
Operator derives from the Service, so they do not depend on the scrape's job
name; set `metrics.prometheusRule.rules` to replace them with your own.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules for pod scheduling. |
| comfyui.checkEndpoint | string | `"/system_stats"` | Endpoint llama-swap polls to decide ComfyUI is up. ComfyUI does not serve llama.cpp's /health. |
| comfyui.cmd | string | `""` | Override the ComfyUI command entirely. Empty builds it from the values above. Multi-line string, passed to llama-swap as the model's `cmd`. |
| comfyui.concurrencyLimit | int | `50` | Concurrent requests allowed to ComfyUI. |
| comfyui.description | string | `"ComfyUI web UI and API"` | Description in the llama-swap UI. |
| comfyui.displayName | string | `"ComfyUI"` | Display name in the llama-swap UI. |
| comfyui.enabled | bool | `false` | Run the llama-swap + ComfyUI image and register ComfyUI as a model. Replaces `image` with `comfyui.image` and mounts the ComfyUI data volume. |
| comfyui.extraArgs | list | `[]` | Extra command line arguments for ComfyUI, e.g. ["--fast", "--preview-method", "auto"]. |
| comfyui.group | string | `""` | Group to add ComfyUI to. Empty leaves it in the default group. |
| comfyui.home | string | `"/opt/comfyui"` | Where ComfyUI is installed in the image. Holds `app/` and the `venv/` that torch lives in. |
| comfyui.httpRoute.annotations | object | `{}` | Annotations for the HTTPRoute. |
| comfyui.httpRoute.enabled | bool | `false` | Expose ComfyUI through a Gateway API HTTPRoute of its own. |
| comfyui.httpRoute.hostnames | list | `["comfyui.local"]` | Hostnames served by this route. |
| comfyui.httpRoute.labels | object | `{}` | Extra labels for the HTTPRoute. |
| comfyui.httpRoute.parentRefs | list | `[{"name":"hauke-cloud","namespace":"envoy-gateway"}]` | Gateways this route attaches to. |
| comfyui.httpRoute.paths | list | `["/"]` | Path prefixes matched on those hostnames. Serving ComfyUI from a subpath works too: use e.g. /comfy and it is rewritten onto ComfyUI's path. |
| comfyui.httpRoute.replacePrefixMatch | string | `""` | Prefix the request is rewritten onto. Empty derives it from `comfyui.name`. |
| comfyui.httpRoute.rewrite | bool | `true` | Rewrite the matched prefix onto ComfyUI's path with a URLRewrite filter, so the browser asks for /foo and llama-swap sees /comfyui/foo. Leaving this false with `paths: ["/"]` publishes all of llama-swap — its API and UI included — on this hostname. |
| comfyui.httpRoute.rules | list | `[]` | Route rules. Empty builds them from `paths` and `rewrite` above; set this to take full control, and `paths`/`rewrite` are then ignored. |
| comfyui.httpRoute.timeouts | object | `{"backendRequest":"0s","request":"0s"}` | Per-request timeouts. |
| comfyui.ignoreWebsockets | bool | `true` | Keep websockets out of swap, concurrency and TTL accounting, so an open browser tab does not pin ComfyUI to the GPU forever. |
| comfyui.image.repository | string | `"ghcr.io/hauke-cloud/llama-swap-comfyui"` | ComfyUI image repository. |
| comfyui.image.tag | string | `"cuda-non-root"` | ComfyUI image tag. `-non-root` matches the uid/gid the securityContext expects. |
| comfyui.ingress.annotations | object | `{}` | Annotations for the ComfyUI Ingress. |
| comfyui.ingress.className | string | `""` | IngressClass name. Unlike `ingress.className` this does not default to anything; empty uses the cluster's default IngressClass. |
| comfyui.ingress.enabled | bool | `false` | Expose ComfyUI through an Ingress of its own. |
| comfyui.ingress.hosts | list | `[{"host":"comfyui.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress host rules. Serving ComfyUI from a subpath works too: set `path` to e.g. /comfy and it is rewritten onto ComfyUI's path. |
| comfyui.ingress.rewrite | bool | `true` | Rewrite the host root onto ComfyUI's path using ingress-nginx annotations. |
| comfyui.ingress.tls | list | `[]` | TLS configuration. |
| comfyui.injectModel | bool | `true` | Add the ComfyUI model entry to the rendered config. |
| comfyui.name | string | `"comfyui_auto"` | Key of the model entry. `comfyui_auto` unlocks llama-swap's built-in ComfyUI route at /comfyui/; any other value is proxied at /upstream/<name>/. |
| comfyui.ttl | int | `900` | Seconds of inactivity after which ComfyUI is stopped and the GPU freed. |
| comfyui.unlisted | bool | `true` | Hide ComfyUI from /v1/models. |
| env | list | `[]` | Environment variables for the container (list of name/value or name/valueFrom). Referenced from the config as `${env.NAME}`. |
| envFrom | list | `[]` | Additional envFrom sources, e.g. a Secret holding API keys. |
| extraVolumeMounts | list | `[]` | Additional volumeMounts on the container. |
| extraVolumes | list | `[]` | Additional volumes on the pod. |
| fullnameOverride | string | `""` | Override the full generated resource name. |
| gpu.count | int | `1` | Number of devices to request. Added to resources.limits. |
| gpu.enabled | bool | `false` | Request a GPU for the pod. Requires a matching device plugin and a GPU image variant (see image.tag). |
| gpu.resourceName | string | `"nvidia.com/gpu"` | Extended resource name, e.g. nvidia.com/gpu, amd.com/gpu, gpu.intel.com/i915. |
| httpRoute.annotations | object | `{}` | Annotations for the HTTPRoute. |
| httpRoute.enabled | bool | `false` | Expose llama-swap through a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `["llama-swap.local"]` | Hostnames served by this route. Each must match a listener hostname on the parent Gateway. |
| httpRoute.labels | object | `{}` | Extra labels for the HTTPRoute. |
| httpRoute.parentRefs | list | `[{"name":"hauke-cloud","namespace":"envoy-gateway"}]` | Gateways this route attaches to. |
| httpRoute.rules | list | `[]` | Route rules. Empty emits one rule matching everything under `/`. Entries without `backendRefs` are pointed at this chart's Service, so a rule usually only carries `matches` and `filters`. |
| httpRoute.timeouts | object | `{"backendRequest":"0s","request":"0s"}` | Per-request timeouts. |
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
| metrics.prometheusRule.annotations | object | `{}` | Annotations for the PrometheusRule. |
| metrics.prometheusRule.enabled | bool | `false` | Create a PrometheusRule with a default set of alerts. Requires the monitoring.coreos.com CRDs. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels for the PrometheusRule. |
| metrics.prometheusRule.namespace | string | `""` | Namespace the PrometheusRule is created in. Empty uses the release namespace. |
| metrics.prometheusRule.rules | list | `[]` | Alerting rules. Empty uses the chart's defaults, which match on the `service` label the Prometheus Operator derives from this chart's Service, so they work regardless of the scrape's job name. |
| metrics.serviceMonitor.annotations | object | `{}` | Annotations for the ServiceMonitor. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a ServiceMonitor scraping /metrics. Requires the monitoring.coreos.com CRDs. |
| metrics.serviceMonitor.interval | string | `"30s"` | How often Prometheus scrapes /metrics. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels for the ServiceMonitor. Prometheus instances commonly select on a label like `release: prometheus`, which belongs here. |
| metrics.serviceMonitor.namespace | string | `""` | Namespace the ServiceMonitor is created in. Empty uses the release namespace. Prometheus often watches other namespaces, so point this at its own when the Service is scraped from a different one. |
| metrics.serviceMonitor.scrapeTimeout | string | `"10s"` | Give up on a scrape after this long. |
| nameOverride | string | `""` | Override the chart name portion of resource names. |
| nodeSelector | object | `{}` | Node selector for pod scheduling. |
| persistence.comfyui.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.comfyui.annotations | object | `{}` | Annotations for the PVC. |
| persistence.comfyui.enabled | bool | `true` | Mount a volume holding ComfyUI's models and state. |
| persistence.comfyui.existingClaim | string | `""` | Use an existing PVC instead of provisioning one. |
| persistence.comfyui.hostPath | string | `""` | Use a host directory instead of a PVC. Mutually exclusive with existingClaim. |
| persistence.comfyui.mountPath | string | `"/data/comfyui"` | Where the ComfyUI data volume is mounted. Matches the image default. |
| persistence.comfyui.retain | bool | `true` | Keep the PVC when the release is uninstalled. |
| persistence.comfyui.size | string | `"50Gi"` | Volume size. Diffusion checkpoints are large; size for what you plan to install. |
| persistence.comfyui.storageClass | string | `""` | StorageClass. Empty uses the cluster default; "-" disables dynamic provisioning. |
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
* <https://github.com/hauke-cloud/llama-swap-comfyui>
