{{- define "career-ops-dashboard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "career-ops-dashboard.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "career-ops-dashboard.labels" -}}
app: {{ include "career-ops-dashboard.name" . }}
team: joyson
env: prod
app.kubernetes.io/name: {{ include "career-ops-dashboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "career-ops-dashboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "career-ops-dashboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
