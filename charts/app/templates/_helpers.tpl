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

The repository expands by the same rule as the app's own `image`. The tag is
looked for in three places, in this order:

  initImageTags.<name>   written by that image's own pipeline, in its own file
  the entry's imageTag   pinned by hand, typically a third-party image
  the app's imageTag     an image of *ours* with neither of the above

The first exists for a step released on its own cadence — a migrations
repository carrying a schema version — where riding the app's tag would pin it
to a version that means nothing in the registry it came from. It is keyed by the
container's *resolved* name, so an entry with no `name` is keyed by the derived
`init-<image>`.

Setting both `initImageTags.<name>` and the entry's own `imageTag` is refused
rather than resolved. That is the two-sources-of-truth the versions/ split
exists to prevent, and silently picking one would make the quieter file win.

An image of ours with no tag anywhere still rides the app's `imageTag`, because
a migrate or seed image built by the same pipeline carries the same version. A
third-party image has no such relationship and falls back to `latest`.
*/}}
{{- define "app.initImage" -}}
{{- $root := .root -}}
{{- $ic := .container -}}
{{- $repo := include "app.expandImage" (dict "image" $ic.image "root" $root) -}}
{{- $name := include "app.initContainerName" $ic -}}
{{- $pinned := index (default (dict) $root.Values.initImageTags) $name -}}
{{- if and $pinned $ic.imageTag -}}
{{- fail (printf "init container %q takes its tag from both initImageTags (%v) and its own imageTag (%v) — keep whichever one a pipeline writes and drop the other" $name $pinned $ic.imageTag) -}}
{{- end -}}
{{- $tag := default $ic.imageTag $pinned -}}
{{- if and (not $tag) (hasPrefix $root.Values.registry.host $repo) -}}
{{- $tag = $root.Values.imageTag -}}
{{- end -}}
{{- printf "%s:%s" $repo (toString (default "latest" $tag)) -}}
{{- end -}}
