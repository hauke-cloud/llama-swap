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
{{- end }}
