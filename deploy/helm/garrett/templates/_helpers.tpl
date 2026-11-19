{{/* The chart's name, or nameOverride. */}}
{{- define "garrett.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* The DaemonSet's name: fullnameOverride, or the release's name when it has the chart's name in it, or both. */}}
{{- define "garrett.fullname" -}}
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

{{/* The Secret the nodes enrol with: enrolment.existingSecret, or the one this chart makes. */}}
{{- define "garrett.secretName" -}}
{{- if .Values.enrolment.existingSecret }}
{{- .Values.enrolment.existingSecret }}
{{- else }}
{{- printf "%s-enrolment" (include "garrett.fullname" .) }}
{{- end }}
{{- end }}

{{- define "garrett.selectorLabels" -}}
app.kubernetes.io/name: {{ include "garrett.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "garrett.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "garrett.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
