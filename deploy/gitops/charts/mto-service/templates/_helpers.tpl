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

{{/*
La imagen del contenedor. En produccion (global.environment: prod) la etiqueta es la de un commit concreto,
el sha-<commit> que publico el CI del servicio y ya paso por staging: sin etiqueta, o con latest, el chart no
renderiza, y la Application queda sin sincronizar en vez de desplegar lo ultimo que se publico. En los demas
entornos, la que se le de.
*/}}
{{- define "mto-service.image" -}}
{{- $repository := required "image.repository es obligatorio" .Values.image.repository -}}
{{- $tag := toString (default "" .Values.image.tag) -}}
{{- $environment := toString (default "" (default dict .Values.global).environment) -}}
{{- if and (eq $environment "prod") (or (eq $tag "") (eq $tag "latest")) -}}
{{- fail (printf "%s: en produccion image.tag es obligatorio y no puede ser latest (ahora: %q). Pongase el sha-<commit> de %s que ya paso por staging en deploy/gitops/values/prod/<servicio>.yaml (deploy/README.md, Promover a produccion)" (include "mto-service.name" .) $tag $repository) -}}
{{- end -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
