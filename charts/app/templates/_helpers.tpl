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

{{/*
The app's own ClusterSecretStore, scoped to its Infisical folder.

Cluster-scoped names are global, so this is prefixed rather than just `<name>`
— it sits alongside the shared `infisical` store, which now serves only the
registry credential in /platform.
*/}}
{{- define "app.storeName" -}}
{{- printf "infisical-%s" (include "app.name" .) -}}
{{- end -}}

{{- define "app.pullSecretName" -}}
{{- printf "%s-registry" (include "app.name" .) -}}
{{- end -}}

{{/*
The image repository, without the tag.

Everything this platform builds lives under `apps/` in zot, so a bare `image`
means "our own app" and is expanded to <registry.host>/apps/<image>. Anything
containing a slash is already a full reference — traefik/whoami, ghcr.io/x/y, or
a spelled-out registry.matejkovac.sk/apps/nsr — and passes through untouched.
*/}}
{{- define "app.expandImage" -}}
{{- if contains "/" .image -}}
{{- .image -}}
{{- else -}}
{{- printf "%s/apps/%s" .root.Values.registry.host .image -}}
{{- end -}}
{{- end -}}

{{- define "app.imageRepository" -}}
{{- include "app.expandImage" (dict "image" .Values.image "root" .) -}}
{{- end -}}

{{/*
Whether this app pulls from the platform's private registry.

Auto-detected from the resolved repository, so a public image (traefik/whoami)
gets no pull secret and a zot one does — including the bare form, which is
always ours. `registry.pullSecret: true` forces it on — needed when the workload
lives in the app's own chart and `image` is empty here, since there is then
nothing to detect from.
*/}}
{{- define "app.usePullSecret" -}}
{{- if ne (toString .Values.registry.pullSecret) "" -}}
{{- if .Values.registry.pullSecret -}}true{{- end -}}
{{- else -}}
{{- $ours := false -}}
{{- if and .Values.image (hasPrefix .Values.registry.host (include "app.imageRepository" .)) -}}
{{- $ours = true -}}
{{- end -}}
{{- range .Values.initContainers -}}
{{- if and .image (hasPrefix $.Values.registry.host (include "app.expandImage" (dict "image" .image "root" $))) -}}
{{- $ours = true -}}
{{- end -}}
{{- end -}}
{{- if $ours -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
{{- end -}}

{{/*
An init container's name.

Explicit `name` wins. Otherwise it is derived from the image's last path
segment, so `nsr-migrate` becomes init-nsr-migrate and shows up that way in
`kubectl logs` — characters a container name cannot hold are folded to dashes.
*/}}
{{- define "app.initContainerName" -}}
{{- if .name -}}
{{- .name -}}
{{- else -}}
{{- $seg := first (splitList ":" (last (splitList "/" .image))) -}}
{{- printf "init-%s" (trimAll "-" (regexReplaceAll "[^a-z0-9-]" (lower $seg) "-")) -}}
{{- end -}}
{{- end -}}

{{/*
An init container's full image reference.

The repository expands by the same rule as the app's own `image`. The tag is the
entry's own `imageTag` if it sets one; failing that, an image of *ours* rides the
app's `imageTag`, because a migrate or seed image is built by the same pipeline
and carries the same version. A third-party image has no such relationship, so
it falls back to `latest` rather than being handed a version that only means
something in our registry.
*/}}
{{- define "app.initImage" -}}
{{- $root := .root -}}
{{- $repo := include "app.expandImage" (dict "image" .container.image "root" $root) -}}
{{- $tag := .container.imageTag -}}
{{- if and (not $tag) (hasPrefix $root.Values.registry.host $repo) -}}
{{- $tag = $root.Values.imageTag -}}
{{- end -}}
{{- printf "%s:%s" $repo (default "latest" $tag) -}}
{{- end -}}
