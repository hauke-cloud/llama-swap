{{/*
Expand the name of the chart.
*/}}
{{- define "llama-swap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "llama-swap.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "llama-swap.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "llama-swap.labels" -}}
helm.sh/chart: {{ include "llama-swap.chart" . }}
{{ include "llama-swap.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "llama-swap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "llama-swap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "llama-swap.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "llama-swap.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the ConfigMap holding config.yaml
*/}}
{{- define "llama-swap.configMapName" -}}
{{- if .Values.llamaSwap.existingConfigMap }}
{{- .Values.llamaSwap.existingConfigMap }}
{{- else }}
{{- printf "%s-config" (include "llama-swap.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Name of the models PVC created by this chart
*/}}
{{- define "llama-swap.modelsClaimName" -}}
{{- if .Values.persistence.models.existingClaim }}
{{- .Values.persistence.models.existingClaim }}
{{- else }}
{{- printf "%s-models" (include "llama-swap.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Name of the state PVC created by this chart
*/}}
{{- define "llama-swap.dataClaimName" -}}
{{- if .Values.persistence.data.existingClaim }}
{{- .Values.persistence.data.existingClaim }}
{{- else }}
{{- printf "%s-data" (include "llama-swap.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Container image. comfyui.enabled swaps in the combined llama-swap + ComfyUI
image, which is a different repository with its own tag scheme.
*/}}
{{- define "llama-swap.image" -}}
{{- $repository := .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.comfyui.enabled -}}
{{- $repository = .Values.comfyui.image.repository -}}
{{- $tag = .Values.comfyui.image.tag -}}
{{- end -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end }}

{{/*
Name of the ComfyUI data PVC created by this chart
*/}}
{{- define "llama-swap.comfyuiClaimName" -}}
{{- if .Values.persistence.comfyui.existingClaim }}
{{- .Values.persistence.comfyui.existingClaim }}
{{- else }}
{{- printf "%s-comfyui" (include "llama-swap.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Whether the ComfyUI data volume is mounted into the pod.
*/}}
{{- define "llama-swap.comfyuiVolumeEnabled" -}}
{{- if and .Values.comfyui.enabled .Values.persistence.comfyui.enabled -}}
true
{{- end -}}
{{- end }}

{{/*
The ComfyUI model entry, as llama-swap expects it. --base-directory points at
the mounted volume, so models, custom nodes, input, output and user settings
all live on it.
*/}}
{{- define "llama-swap.comfyuiModel" -}}
{{- $c := .Values.comfyui -}}
name: {{ $c.displayName | quote }}
description: {{ $c.description | quote }}
cmd: |
  {{- if $c.cmd }}
  {{- $c.cmd | nindent 2 }}
  {{- else }}
  {{ printf "%s/venv/bin/python" (trimSuffix "/" $c.home) }} {{ printf "%s/app/main.py" (trimSuffix "/" $c.home) }}
  --listen 127.0.0.1
  --port ${PORT}
  --base-directory {{ trimSuffix "/" .Values.persistence.comfyui.mountPath }}
  --disable-auto-launch
  {{- range $c.extraArgs }}
  {{ . }}
  {{- end }}
  {{- end }}
proxy: "http://127.0.0.1:${PORT}"
checkEndpoint: {{ $c.checkEndpoint | quote }}
unlisted: {{ $c.unlisted }}
ttl: {{ $c.ttl }}
{{- end }}

{{/*
The llama-swap configuration as rendered into the ConfigMap: llamaSwap.config
with the ComfyUI model merged in. An entry that already exists under
comfyui.name wins, so a hand-written one is never overwritten.
*/}}
{{- define "llama-swap.config" -}}
{{- $config := deepCopy (default (dict) .Values.llamaSwap.config) -}}
{{- if and .Values.comfyui.enabled .Values.comfyui.injectModel -}}
{{- $models := deepCopy (default (dict) (get $config "models")) -}}
{{- if not (hasKey $models .Values.comfyui.name) -}}
{{- $_ := set $models .Values.comfyui.name (include "llama-swap.comfyuiModel" . | fromYaml) -}}
{{- $_ := set $config "models" $models -}}
{{- if .Values.comfyui.group -}}
{{- $groups := deepCopy (default (dict) (get $config "groups")) -}}
{{- $group := deepCopy (default (dict "swap" true "exclusive" true) (get $groups .Values.comfyui.group)) -}}
{{- $members := default (list) (get $group "members") -}}
{{- if not (has .Values.comfyui.name $members) -}}
{{- $_ := set $group "members" (append $members .Values.comfyui.name) -}}
{{- end -}}
{{- $_ := set $groups .Values.comfyui.group $group -}}
{{- $_ := set $config "groups" $groups -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $config -}}
{{- end }}

{{/*
Full path of the config file inside the container. The ConfigMap is mounted as
a directory (not a subPath) so that Kubernetes propagates updates to the file,
which is what makes llamaSwap.watchConfig useful.
*/}}
{{- define "llama-swap.configPath" -}}
{{- printf "%s/%s" (.Values.llamaSwap.configMountPath | trimSuffix "/") .Values.llamaSwap.configKey }}
{{- end }}

{{/*
Container resources, with the GPU limit merged in when gpu.enabled is set.
Extended resources may only be set as a limit; Kubernetes derives the request.
*/}}
{{- define "llama-swap.resources" -}}
{{- $resources := deepCopy (default (dict) .Values.resources) -}}
{{- if .Values.gpu.enabled -}}
{{- $limits := deepCopy (default (dict) (get $resources "limits")) -}}
{{- $_ := set $limits .Values.gpu.resourceName .Values.gpu.count -}}
{{- $_ := set $resources "limits" $limits -}}
{{- end -}}
{{- toYaml $resources -}}
{{- end }}

{{/*
Fail early on value combinations that produce a broken release.
*/}}
{{- define "llama-swap.validateValues" -}}
{{- if and (not .Values.llamaSwap.existingConfigMap) (not .Values.llamaSwap.config) }}
{{- fail "llama-swap: set either llamaSwap.config or llamaSwap.existingConfigMap" }}
{{- end }}
{{- if and .Values.persistence.models.existingClaim .Values.persistence.models.hostPath }}
{{- fail "llama-swap: persistence.models.existingClaim and persistence.models.hostPath are mutually exclusive" }}
{{- end }}
{{- if and .Values.persistence.models.hostPath (not .Values.persistence.models.enabled) }}
{{- fail "llama-swap: persistence.models.hostPath requires persistence.models.enabled=true" }}
{{- end }}
{{- if and .Values.gpu.enabled (not .Values.gpu.resourceName) }}
{{- fail "llama-swap: gpu.enabled requires gpu.resourceName (e.g. nvidia.com/gpu)" }}
{{- end }}
{{- if .Values.comfyui.enabled }}
{{- if not .Values.comfyui.image.repository }}
{{- fail "llama-swap: comfyui.enabled requires comfyui.image.repository" }}
{{- end }}
{{- if not .Values.comfyui.image.tag }}
{{- fail "llama-swap: comfyui.enabled requires comfyui.image.tag (e.g. cuda-non-root)" }}
{{- end }}
{{- if and .Values.comfyui.injectModel .Values.llamaSwap.existingConfigMap }}
{{- fail "llama-swap: comfyui.injectModel cannot patch llamaSwap.existingConfigMap — add the comfyui model to that ConfigMap yourself and set comfyui.injectModel=false" }}
{{- end }}
{{- if and .Values.persistence.comfyui.existingClaim .Values.persistence.comfyui.hostPath }}
{{- fail "llama-swap: persistence.comfyui.existingClaim and persistence.comfyui.hostPath are mutually exclusive" }}
{{- end }}
{{- if and .Values.persistence.comfyui.hostPath (not .Values.persistence.comfyui.enabled) }}
{{- fail "llama-swap: persistence.comfyui.hostPath requires persistence.comfyui.enabled=true" }}
{{- end }}
{{- end }}
{{- end }}
