{{/*
Expand the name of the chart.
*/}}
{{- define "edge-processor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name for the StatefulSet (kept stable for scripts and docs)
*/}}
{{- define "edge-processor.fullname" -}}
ep-deployment
{{- end }}

{{/*
Common labels
*/}}
{{- define "edge-processor.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "edge-processor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: ep
{{- end }}

{{/*
Selector labels
*/}}
{{- define "edge-processor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "edge-processor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: ep
{{- end }}
