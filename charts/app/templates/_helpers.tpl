{{/*
The convention lives here. Every other template derives its names from these,
so changing a rule changes it everywhere at once.
*/}}

{{- define "app.name" -}}
{{- required "set `name` — it drives the namespace, secret path and ingress" .Values.name -}}
{{- end -}}

{{/* Namespace, app name and Infisical folder are all the same string. */}}
{{- define "app.namespace" -}}
{{- include "app.name" . -}}
{{- end -}}

{{- define "app.secretName" -}}
{{- printf "%s-secrets" (include "app.name" .) -}}
{{- end -}}

{{- define "app.tlsSecretName" -}}
{{- printf "%s-tls" (include "app.name" .) -}}
{{- end -}}

{{/* Infisical folder: /<name> unless explicitly overridden. */}}
{{- define "app.secretsPath" -}}
{{- if .Values.secrets.path -}}
{{- .Values.secrets.path -}}
{{- else -}}
{{- printf "/%s" (include "app.name" .) -}}
{{- end -}}
{{- end -}}

{{- define "app.pullSecretName" -}}
{{- printf "%s-registry" (include "app.name" .) -}}
{{- end -}}

{{/*
Whether this app pulls from the platform's private registry.

Auto-detected from the image, so a public image (traefik/whoami) gets no pull
secret and a zot one does. `registry.pullSecret: true` forces it on — needed
when the workload lives in the app's own chart and `image` is empty here, since
there is then nothing to detect from.
*/}}
{{- define "app.usePullSecret" -}}
{{- if ne (toString .Values.registry.pullSecret) "" -}}
{{- if .Values.registry.pullSecret -}}true{{- end -}}
{{- else if and .Values.image (hasPrefix .Values.registry.host .Values.image) -}}
true
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
{{- end -}}