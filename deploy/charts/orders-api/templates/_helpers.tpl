{{- define "orders-api.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "orders-api.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "orders-api.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: otel-play
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "orders-api.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}

{{/*
Environment shared by everything that runs the app image. It only uses values
and the mysql chart's Secret, never resources from this chart, because the
migration Job is a pre-install hook and runs before they exist.
*/}}
{{- define "orders-api.env" -}}
- name: APP_NAME
  value: orders-api
- name: APP_ENV
  value: {{ .Values.app.env | quote }}
- name: APP_DEBUG
  value: {{ .Values.app.debug | quote }}
- name: LOG_CHANNEL
  value: stderr
- name: LOG_STDERR_FORMATTER
  value: Monolog\Formatter\JsonFormatter
- name: LOG_LEVEL
  value: {{ .Values.app.logLevel | quote }}
- name: DB_CONNECTION
  value: mysql
- name: DB_HOST
  value: {{ .Values.database.host | quote }}
- name: DB_PORT
  value: {{ .Values.database.port | quote }}
- name: DB_DATABASE
  value: {{ .Values.database.name | quote }}
- name: DB_USERNAME
  value: {{ .Values.database.username | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.passwordSecret.name }}
      key: {{ .Values.database.passwordSecret.key }}
- name: REDIS_HOST
  value: {{ .Values.redis.host | quote }}
- name: REDIS_PORT
  value: {{ .Values.redis.port | quote }}
- name: QUEUE_CONNECTION
  value: redis
- name: CACHE_STORE
  value: redis
- name: SESSION_DRIVER
  value: array
- name: CATALOGUE_URL
  value: {{ .Values.app.catalogueUrl | quote }}
- name: CORS_ALLOWED_ORIGINS
  value: {{ .Values.app.corsAllowedOrigins | quote }}
{{- range $name, $value := .Values.env }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end -}}
