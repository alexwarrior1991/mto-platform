{{- define "mto-realm.labels" -}}
app.kubernetes.io/name: mto-realm
app.kubernetes.io/part-of: mto
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* El pod que clona los repositorios en /work/repos: comun al Job que aplica y al que comprueba. */}}
{{- define "mto-realm.clone" -}}
- name: clone
  image: {{ .Values.images.python }}
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
  env:
    - name: HOME
      value: /work
    - name: GIT_BASE_URL
      value: {{ .Values.git.baseUrl | quote }}
    - name: GIT_REVISION
      value: {{ .Values.git.revision | quote }}
    - name: GIT_REPOSITORIES
      value: {{ join " " .Values.git.repositories | quote }}
    {{- with .Values.git.tokenSecret }}
    - name: GIT_TOKEN
      valueFrom:
        secretKeyRef:
          name: {{ . }}
          key: token
    {{- end }}
  command:
    - /bin/bash
    - -ec
    - |
      # El token, si hay, por un credential helper: nunca en la URL, que acabaria en el log de git.
      if [ -n "${GIT_TOKEN:-}" ]; then
        git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GIT_TOKEN}"; }; f'
      fi
      mkdir -p /work/repos
      for repo in ${GIT_REPOSITORIES}; do
        git clone --quiet --depth 1 --branch "${GIT_REVISION}" "${GIT_BASE_URL}/${repo}.git" "/work/repos/${repo}"
      done
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  volumeMounts:
    - name: work
      mountPath: /work
{{- end -}}

{{- define "mto-realm.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "mto-realm.adminEnv" -}}
- name: KC_BOOTSTRAP_ADMIN_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.keycloak.adminSecret }}
      key: username
- name: KC_BOOTSTRAP_ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.keycloak.adminSecret }}
      key: password
{{- end -}}
