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

{{/* ---------------------------------------------------------------- backup */}}

{{/*
The label that ties a PreBackupPod to one destination's Schedule. Its absence is
what marks the app's own objects (PVCs, the app pods) as fair game for every
destination — see the labelSelectors in backup.yaml.
*/}}
{{- define "app.backupDestinationLabel" -}}
app.kovostack/backup-destination
{{- end -}}

{{/*
Destinations that are switched on, as a sorted list of keys. An entry is on
unless it says `enabled: false`, so adding one is a values change of a single
map entry and turning the default one off does not require deleting it.
*/}}
{{- define "app.backupDestinations" -}}
{{- $out := list -}}
{{- range $k, $d := .Values.backup.destinations -}}
{{- if and $d (ne (toString $d.enabled) "false") -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,18}[a-z0-9])?$" $k) -}}
{{- fail (printf "backup.destinations.%s: destination keys must be lowercase alphanumerics and dashes, at most 20 characters — they end up in K8up object names, which K8up extends and truncates at 63" $k) -}}
{{- end -}}
{{- $out = append $out $k -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
Whether a persistence entry is included in the file-level backup: every volume,
unless the entry says `backup: false` (scratch space, caches, re-derivable data).
*/}}
{{- define "app.backupVolume" -}}
{{- if and .root.Values.backup.enabled (ne (toString .vol.backup) "false") -}}true{{- end -}}
{{- end -}}

{{/* A mountPath with exactly one leading slash and no trailing one. */}}
{{- define "app.absPath" -}}
{{- printf "/%s" (trimAll "/" .) -}}
{{- end -}}

{{/*
Each SQLite file resolved to the volume it lives on, as JSON:

  {"files": [{"path": "/app/data/nsr.db", "key": "data", "rel": "nsr.db"}]}

`path` is where the app sees the file, `key` the persistence entry holding it
(deepest mountPath wins), `rel` the file's path inside the PVC — which differs
from the part below mountPath when the entry sets a subPath. A path on no volume
is refused: it is on the container's own filesystem, which is gone the moment
the pod is, and a dump pod could not see it anyway.
*/}}
{{- define "app.sqliteFiles" -}}
{{- $root := . -}}
{{- $files := list -}}
{{- range $i, $f := .Values.backup.sqlite.files -}}
{{- if not (regexMatch "^/?[A-Za-z0-9._/-]+$" (toString $f)) -}}
{{- fail (printf "backup.sqlite.files[%d] %q: use a plain path — letters, digits, . _ - and /" $i (toString $f)) -}}
{{- end -}}
{{- $path := include "app.absPath" $f -}}
{{- $best := "" -}}
{{- $bestMount := "" -}}
{{- range $k, $v := $root.Values.persistence -}}
{{- $mp := include "app.absPath" (required (printf "persistence.%s.mountPath is required" $k) $v.mountPath) -}}
{{- if and (hasPrefix (printf "%s/" (trimSuffix "/" $mp)) $path) (gt (len $mp) (len $bestMount)) -}}
{{- $best = $k -}}
{{- $bestMount = $mp -}}
{{- end -}}
{{- end -}}
{{- if not $best -}}
{{- fail (printf "backup.sqlite.files[%d] %q is not under any persistence mountPath — only a file on a volume survives the pod, and only a volume can be mounted into the dump pod" $i $path) -}}
{{- end -}}
{{- $rel := trimPrefix (printf "%s/" (trimSuffix "/" $bestMount)) $path -}}
{{- with (index $root.Values.persistence $best).subPath -}}
{{- $rel = printf "%s/%s" (trimAll "/" .) $rel -}}
{{- end -}}
{{- $files = append $files (dict "path" $path "key" $best "rel" $rel) -}}
{{- end -}}
{{- toJson (dict "files" $files) -}}
{{- end -}}

{{/*
A cron slot for one destination, derived from `<name>/<destination>` so it is
stable across renders (no ArgoCD drift) yet differs between apps, which keeps
every app from hitting the gateway — and the Storage Box's connection limit —
at the same minute.

Cron is read in the K8up operator's time zone (Europe/Bratislava here):

  backup  daily,      at HH:MM with HH one of 00, 01, 03, 04
  check   Wednesdays, four hours after the backup slot
  prune   Sundays,    four hours after the backup slot

02:xx is skipped on purpose: on DST change days that hour happens twice or not
at all, so a job there runs twice or is skipped. K8up's own @daily-random is not
used either: it spreads over all 24 hours, and a restic prune holds an exclusive
repository lock that a daytime backup would run into. Four hours later leaves a
nightly backup ample time to finish first.
*/}}
{{- define "app.backupSlot" -}}
{{- $h := atoi (adler32sum (printf "%s/%s" (include "app.name" .root) .dest)) -}}
{{- $minute := mod $h 60 -}}
{{- $hour := index (list 0 1 3 4) (mod (div $h 60) 4) -}}
{{- toJson (dict
      "backup" (printf "%d %d * * *" $minute $hour)
      "check" (printf "%d %d * * 3" $minute (add $hour 4))
      "prune" (printf "%d %d * * 0" $minute (add $hour 4))) -}}
{{- end -}}

{{/* A name for an env var the dump script reads, checked so it is safe to splice into sh. */}}
{{- define "app.backupEnvName" -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" .value) -}}
{{- fail (printf "backup.postgres.%s %q is not a valid environment variable name" .field .value) -}}
{{- end -}}
{{- .value -}}
{{- end -}}
