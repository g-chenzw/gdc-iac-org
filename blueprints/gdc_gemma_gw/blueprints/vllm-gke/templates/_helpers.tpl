{{- define "vllm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vllm.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vllm.namespace" -}}
{{- coalesce .Values.global.namespace .Values.namespace .Release.Namespace -}}
{{- end -}}

{{- define "vllm.image" -}}
{{- $repo := .Values.image.repository -}}
{{- $globalReg := .Values.global.registry -}}
{{- if and $globalReg (or (eq $repo "vllm/vllm-openai") (hasPrefix "harbor.gdc.local/" $repo)) -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $globalReg) (base $repo) (.Values.image.tag | default "latest") -}}
{{- else -}}
{{- printf "%s:%s" $repo (.Values.image.tag | default "latest") -}}
{{- end -}}
{{- end -}}

{{- define "vllm.labels" -}}
app.kubernetes.io/name: {{ include "vllm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

