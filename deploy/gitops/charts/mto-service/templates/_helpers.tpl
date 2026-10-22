{{- define "mto-service.name" -}}
{{- required "name es obligatorio: mto-<servicio>" .Values.name -}}
{{- end -}}

{{- define "mto-service.labels" -}}
app.kubernetes.io/name: {{ include "mto-service.name" . }}
app.kubernetes.io/part-of: mto
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "mto-service.selector" -}}
app.kubernetes.io/name: {{ include "mto-service.name" . }}
{{- end -}}
