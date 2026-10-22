{{- define "mto-infra.labels" -}}
app.kubernetes.io/part-of: mto
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* El host de una URL (https://auth.example.com -> auth.example.com). */}}
{{- define "mto-infra.host" -}}
{{- regexReplaceAll "^https?://([^/:]+).*$" . "${1}" -}}
{{- end -}}
