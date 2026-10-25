{{- define "mysql.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mysql.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mysql.labels" -}}
{{ include "mysql.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: otel-play
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
