# charts/app

The repeating resources every migrated app needs, driven by one value.

`name` decides everything:

| | derived as |
|---|---|
| namespace | `<name>` |
| Infisical folder | `/<name>` |
| synced Secret | `<name>-secrets` |
| TLS Secret | `<name>-tls` |
| Service / Ingress / Deployment | `<name>` |

So a whole app can be:

```yaml
# applications/whoami/values.yaml
name: whoami
image: traefik/whoami
host: whoami.matejkovac.sk
containerPort: 80
```

That renders a Namespace, an ExternalSecret syncing Infisical `/whoami`, a
Deployment with those secrets as env vars, a Service, and an Ingress with a
cert-manager certificate.

## Images

Everything this platform builds is pushed under `apps/` in zot, so a **bare
`image` is one of ours** and the chart expands it:

| `image` | pulled as |
|---|---|
| `nsr` | `registry.matejkovac.sk/apps/nsr` |
| `traefik/whoami` | `traefik/whoami` |
| `ghcr.io/owner/thing` | `ghcr.io/owner/thing` |
| `registry.matejkovac.sk/apps/nsr` | unchanged |

The rule is the slash: anything containing one is already a full reference and
is taken as written, so third-party images and previously spelled-out paths both
keep working. `imageTag` is appended to whichever form results, and defaults to
`latest`.

## What renders when

Two values act as switches, so the chart also suits apps that are not a simple
web deployment:

- **`image` empty** → no Deployment or Service. Namespace, secrets and ingress
  only, for an app whose workload comes from its own chart.
- **`host` empty** → no Ingress or certificate. For workers, cron jobs and
  anything with no public route.
- **`secrets.enabled: false`** → no ExternalSecret, for an app with no secrets.
- **`backup.enabled: true`** → K8up Schedule, dump pods and backup credentials;
  off by default. See [Backups](#backups).

## Health probes

`healthPath` alone gives both probes the same path, which suits an app with one
health endpoint. An app that can tell the two questions apart should:

```yaml
healthPath: /actuator/health                   # kept as the fallback
readinessPath: /actuator/health/readiness      # "send me traffic?"
livenessPath: /actuator/health/liveness        # "am I stuck?" - restarts the container
```

The difference matters as soon as a health check includes a dependency. With one
path for both, a database outage fails liveness on every replica at once and
Kubernetes restarts them all - which fixes nothing, since the database is still
down, and turns an outage into a crash loop. Liveness should fail only for
something a restart cures. Each of the two falls back to `healthPath`, and a
probe with no path at all is not rendered.

## Serving www as well

`wwwAlias: true` adds `www.<host>` as a second rule on the Ingress and a second
name on the same certificate:

```yaml
host: kovo.space
wwwAlias: true      # serves kovo.space and www.kovo.space
```

Off by default, because it only makes sense for an apex domain — for
`nsr.matejkovac.sk`, `www.nsr.matejkovac.sk` is not a name anyone types. The
chart refuses a `host` that already starts with `www.` rather than asking for
`www.www.…`.

⚠️ **Create the DNS record first.** Both names share one certificate, so if
`www.<host>` has no record pointing at the cluster, its HTTP-01 challenge fails
and the whole certificate fails with it — including the apex, which was serving
fine a minute earlier. Let's Encrypt rate-limits *failures* at 5/hour per
domain, so switch `clusterIssuer` to `letsencrypt-staging` until
`kubectl -n <app> get certificate` reports `READY=True`, then flip it back.

Both names serve the app directly; neither redirects to the other. Search
engines treat them as duplicate content, so pick one as canonical in the app
itself, or add a Traefik redirect middleware.

## Init containers

Steps that must finish before the app starts — a migration, a seed, waiting on
a dependency. `initContainers` is a **list**, and Kubernetes runs the entries
one at a time in the order written; the first failure stops the pod there.

```yaml
name: nsr
image: nsr
imageTag: v2.4.1

initContainers:
  - image: docker.io/library/busybox
    imageTag: "1.36"
    command: ["sh", "-c", "until nc -z postgres 5432; do sleep 1; done"]
  - image: nsr-migrate
    command: ["./manage.py", "migrate"]
  - image: nsr-seed
```

renders three init containers that run in exactly that order, then the app.

Only `image` is required per entry. `name` defaults to `init-<last path segment
of image>` — the middle entry above becomes `init-nsr-migrate`, which is what
`kubectl logs` wants from you. `command`, `args`, `env`, `resources` and
`imagePullPolicy` behave as they do on the app container.

**It is a list and not a map on purpose.** `persistence` and `externalServices`
are maps because their entries are unordered; Helm iterates map keys in sorted
order, so a map here would quietly run your seed before your migration.

### Where the parameters come from

Every entry inherits, without repeating any of it:

| | inherited from |
|---|---|
| `envFrom` | the app's synced Secret — every key in its Infisical folder |
| `env` | the chart's `env:`, overridable per entry |
| `volumeMounts` | the same `persistence:` volumes, at the same paths |

So a migration reads the same `DATABASE_URL` as the app *by construction*,
whether that value comes from `env:` in the gitops repo or from Infisical. There
is no second place to wire it, and no way for the two to drift.

A per-entry `env` wins over the shared one for that container only:

```yaml
env:
  LOG_LEVEL: info           # app and every init container

initContainers:
  - image: nsr-seed
    env:
      LOG_LEVEL: debug      # this container only
```

### Tags

An entry with no `imageTag` that resolves to **our** registry rides the app's
`imageTag`, because a migrate image is built by the same pipeline and carries
the same version — so one bump in `versions/<app>.yaml` moves the app and its
migration together. In the example above, `nsr-migrate` and `nsr-seed` both
resolve to `v2.4.1`.

An image from anywhere else falls back to `latest`, so pin it. Watch the slash
rule while you do: a bare `busybox` is read as *ours* and becomes
`<registry>/apps/busybox`. The public one is `docker.io/library/busybox`.

An init container pulled from our registry gets the `imagePullSecret` too, even
when the app's own `image` is public.

⚠️ **A second values file replaces this list wholesale.** Helm never merges
lists element by element, so `versions/<app>.yaml` cannot reach inside an entry
to set its `imageTag` — it would have to restate every entry. Keep the whole
list in the app's values file.

#### A step with its own version

Some init containers are not built by the app's pipeline and do not carry its
version — a migrations repository publishing a schema version of its own. For
those, `initImageTags` is a **map**, keyed by the container's name, and a map
*does* merge across values files:

```yaml
# applications/<app>/values.yaml — edited by humans
initContainers:
  - name: migrations
    image: new-tab-links-migrations

# versions/<app>-init.yaml — written by the migrations pipeline
initImageTags:
  migrations: "1.2.3"
```

Both version files load after the app's values and neither overwrites the other,
because `imageTag` and `initImageTags` are different keys. The key is the
container's *resolved* name: `migrations` above, but `init-nsr-seed` for an
entry that sets no `name`. Quote the value — an unquoted `1.2` is a YAML float.

Setting `initImageTags.<name>` and that entry's own `imageTag` is refused rather
than resolved, for the same reason `imageTag` lives only in `versions/`: two
sources of truth where the quieter one always wins.

Init containers render only when `image` is set — no Deployment, no init
containers.

## Secrets

Everything in the app's Infisical folder is synced into one Secret and mounted
with `envFrom`, so **adding a secret in Infisical requires no change in git** —
it appears as an env var on the next refresh (default hourly).

Consequences worth knowing:

- Infisical key names become env var names verbatim. Name them as such
  (`DATABASE_URL`, not `database url`).
- Everything in the folder reaches the container. Don't park unrelated secrets
  in an app's folder.
- The Secret is `creationPolicy: Owner`, so deleting the app deletes its
  credentials from the cluster rather than orphaning them.
- Key names only have to be unique **within** the folder. Two apps may both have
  a `PAYLOAD_SECRET`; see below for why that is worth stating.

Override the folder with `secrets.path` only when an app genuinely cannot own
one named after itself — the convention is the feature.

### Why each app gets its own store

The chart renders a `ClusterSecretStore` per app (`infisical-<name>`), scoped to
that app's folder with `recursive: false`, and the app's ExternalSecret reads
from it.

That looks redundant next to `dataFrom.find.path`, and it is not.
external-secrets' Infisical provider **does not send `find.path` to the API**:
it fetches whatever the *store* is scoped to, then flattens the response into a
map keyed by secret name alone. With every app sharing one store rooted at `/`
with `recursive: true`, each app pulled the entire project on every refresh, and
two folders holding the same key name collided — one app got the value, the
other silently got nothing, with no error and a green sync. Which app won could
change on any resync.

That is not hypothetical: `/kovo` and `/nsr` both hold `PAYLOAD_SECRET`, and
`/paster-backend` and `/music-pages-scraper-backend` both hold
`SPRING_DATASOURCE_USER` and `SPRING_DATASOURCE_PASS`. Three keys, three apps
quietly missing an env var.

Scoping the store is what actually narrows the fetch, so an app can only ever
see its own folder. The cost is that `secrets.infisical.*` in `values.yaml`
duplicates the `infisical.*` block in the gitops repo's
`infrastructure/external-secrets/values.yaml` — same host, project, environment
and machine identity. **Change one, change the other.**

The shared `infisical` store still exists and is still rooted at `/`, but its
only remaining consumer is the registry credential below.

## Pulling from the private registry

zot denies anonymous access, so an image from it needs a credential. The chart
renders one **automatically when the resolved image sits on `registry.host`**: a
public image gets nothing, while `nsr` — or the long
`registry.matejkovac.sk/apps/nsr` — gets a `kubernetes.io/dockerconfigjson`
Secret named `<name>-registry` plus the matching `imagePullSecrets` entry.

There is no dockerconfigjson in git, and there should never be one — that file
is base64, not encryption, so committing it publishes the robot's password. Git
holds only the *name* of the Infisical key; the value is fetched by
external-secrets and assembled in the cluster.

```
Infisical  /platform/ZOT_K8S_PASSWORD
      │  external-secrets, hourly
      ▼
Secret  <app>-registry   (kubernetes.io/dockerconfigjson, one per namespace)
      │
      ▼
kubelet pulls  registry.matejkovac.sk/apps/<app>
```

- The credential is the read-only **`k8s` robot** from zot's `accessControl`: it
  can pull `apps/**` and `charts/**` and push nothing, so a compromised node
  cannot overwrite an image.
- One Secret per namespace — `imagePullSecrets` cannot cross namespaces. It is
  the same robot each time, not one per app.
- Set `registry.pullSecret: true` for an app whose workload lives in its own
  chart: `image` is empty here, so there is nothing to detect. That chart then
  references `<name>-registry` itself.
- This is the one thing still read through the shared `infisical` store, which
  is rooted at `/` and recursive. `registry.passwordKey` must therefore stay
  unique across every folder in the project — see "Why each app gets its own
  store". App secrets are not subject to this.
- Rotating the password is a change in Infisical only. New pulls pick it up on
  the next refresh; running pods are unaffected, their pull already happened.

## Reaching services outside the cluster

Postgres, Redis and the rest of the platform stack run in Docker on the VM, not
in Kubernetes. `externalServices` gives each a name inside the cluster:

```yaml
externalServices:
  postgres:
    address: 172.17.0.1     # must be an IP; hostnames are not valid here
    port: 5432
```

The app then connects to `postgres:5432` like any in-cluster service. It renders
a **Service with no selector** plus a matching **EndpointSlice** — the standard
way to point cluster DNS at something outside it.

The value is the indirection. The app never learns where the database actually
is, so moving it — to another host, or into the cluster later — changes this one
entry rather than every connection string in Infisical.

⚠️ **`address` must be reachable from a pod.** The host's `127.0.0.1` is not:
inside a pod that is the pod's own loopback, which is the same trap that broke
the ACME challenge path. Bind the container to a host address (`POSTGRES_BIND`
in the platform `.env`) and use that one.

Prefer a **private** address such as the `docker0` gateway over the VM's public
IP. A database bound to a public address is protected by nothing but a firewall
rule, and that is one mistake away from being open to the internet.

Rendering fails immediately if `address` or `port` is missing, or if the name
collides with the app's own Service.

## Storage

Each `persistence` entry becomes a PVC named `<name>-<key>`, mounted at its
`mountPath`:

```yaml
persistence:
  data:
    size: 1Gi
    mountPath: /app/data
  uploads:
    size: 10Gi
    mountPath: /app/uploads
```

Three things the chart does on your behalf, all of them about not losing data:

- **`Recreate` deployment strategy** as soon as any volume exists. A rolling
  update starts the new pod before stopping the old one, and a ReadWriteOnce
  volume cannot attach to both — the new pod blocks on attach, and if it ever
  did succeed, two processes sharing one SQLite file corrupt it.
- **`replicas > 1` is refused** with a ReadWriteOnce volume, at template time
  rather than as a pod stuck in `ContainerCreating`.
- **`Delete=false` on every PVC _and_ on the Namespace**, so deleting the
  Application never deletes a claim. Both are needed: with the annotation on
  the PVCs alone, ArgoCD skips the claims but still deletes the Namespace, and
  Kubernetes deletes every PVC inside a Namespace along with it. Normal pruning
  still works, so the app never gets stuck OutOfSync — which is why this is
  `Delete=false` and not `Prune=false`.

**Deleting the Application leaves the Namespace and its PVCs behind.** The
Deployment, Service, Ingress, ExternalSecrets (and the Secrets they own) and
the backup objects go; the Namespace and the claims stay, and so do the data.
Recreating the Application picks them up again. Removing them is a deliberate,
manual step:

```bash
kubectl delete namespace <name>    # takes every PVC in it with it
```

Removing a single volume from `persistence` is not affected: that is a prune,
and the claim is deleted as usual.

**What actually protects the data is the StorageClass, not the annotation.**
`local-path-retain` sets `reclaimPolicy: Retain`, so deleting a PVC leaves the
PV and the files on disk. That holds however the claim is removed — pruned by
ArgoCD, deleted by hand, or with the namespace when you delete it yourself.

The limit worth knowing: a retained volume does **not** reattach automatically.
Delete a PVC and recreate it and you get a fresh, empty volume; the old data
sits in a `Released` PV, readable straight off the filesystem and reattachable
only by clearing its `claimRef` by hand:

```bash
kubectl get pv                     # find the Released one
kubectl patch pv <pv> -p '{"spec":{"claimRef":null}}'
```

So the guarantee is "your data is never destroyed", not "your data always comes
back by itself".

Two caveats specific to this cluster, both from k3s' default `local-path`
class:

- **The data lives on one node's disk.** There is no replication and no
  snapshot. Anything here needs its own backup — the cluster is not one. See
  [Backups](#backups).
- **No `allowVolumeExpansion`.** Growing a volume later means creating a new
  claim and copying, so size with headroom now.

## Backups

Off by default. `backup.enabled: true` renders [K8up](https://k8up.io)
(`k8up.io/v1`, written against operator **v2.16.0** / chart 4.10.0) objects
that back the app up every night to a restic repository of its own,
`<url>/<name>/`. With the default destination, that is
`rest:http://restic-gateway.backup.svc.cluster.local:8080/<name>/`, the gateway
in front of the Hetzner Storage Box. A dev instance such as
`new-tab-links-backend-dev` gets its own repository by virtue of its own
`name`.

Three things can be backed up, in any combination:

| | how | lands in the snapshot as |
|---|---|---|
| **volumes** | every `persistence` entry, file by file | `/data/<name>-<key>/…`, one snapshot per volume |
| **sqlite** | `VACUUM INTO` in a dump pod, per file in `backup.sqlite.files` | `/<name>-sqlite.tar` |
| **postgres** | `pg_dump` in a dump pod, over `externalServices` | `/<name>-postgres.sql` (or `.dump`) |

Rendering fails if backup is on and there is nothing to back up. Every snapshot
carries the namespace (= `<name>`) as its restic host.

### The four shapes

```yaml
# Volumes only — an app with uploads and no database.
backup:
  enabled: true
persistence:
  cache:
    backup: false          # opt a scratch volume out; everything else is in
```

```yaml
# Volumes + SQLite — nsr, roulage, kovo-old, istatdb.
backup:
  enabled: true
  sqlite:
    files:
      - /app/data/nsr.db   # the path the app sees, as in DATABASE_URI
```

```yaml
# Volumes + Postgres — kovo (Payload keeps one URL with credentials in it).
backup:
  enabled: true
  postgres:
    enabled: true
    urlEnv: DATABASE_URI
```

```yaml
# Postgres only — new-tab-links-backend (Spring; no volumes).
backup:
  enabled: true
  postgres:
    enabled: true
    urlEnv: SPRING_DATASOURCE_URL          # jdbc:postgresql://postgres:5432/newtablinks
    userEnv: SPRING_DATASOURCE_USERNAME
    passwordEnv: SPRING_DATASOURCE_PASSWORD
```

paster-backend and music-pages-scraper-backend name their credentials
`SPRING_DATASOURCE_USER` / `SPRING_DATASOURCE_PASS` in Infisical, so they set
`userEnv`/`passwordEnv` to those. paster-backend would also set
`persistence.temp.backup: false`. The mapping is per app because
the names are; the chart does not guess.

### What gets rendered

Per enabled destination `<dest>` (default: `gateway`):

| object | name | purpose |
|---|---|---|
| `ExternalSecret` | `<name>-backup-<dest>` | the REST credentials and restic password, from the destination's `store` |
| `Schedule` | `<dest>` | daily backup, weekly check, weekly prune with retention |
| `PreBackupPod` | `sqlite-<dest>`, `postgres-<dest>` | the dump pods, only when sqlite / postgres is on |

plus one `ConfigMap` `<name>-backup-scripts` holding the dump scripts, and two
annotations on each PVC. The K8up objects have short names on purpose. The
namespace already says which app, and K8up derives Backup, Job and Pod names
from them, truncating at 63 characters.

A `PreBackupPod` is only a template. K8up turns it into a Deployment when a
backup starts, execs the dump script in it, streams stdout into restic and
deletes it again.

### Which volumes are backed up

K8up's own rule, with the operator's `skipWithoutAnnotation: false`, is *every*
RWO/RWX PVC in the namespace unless it is annotated `k8up.io/backup: "false"`.
The chart does not leave that to chance, in either direction:

- **Every chart PVC is annotated explicitly**: `"true"`, or `"false"` for a
  `persistence` entry with `backup: false`. The answer is the same however the
  operator is configured.
- **The Schedule selects by label.** Its `labelSelectors` match only objects
  with this app's `app.kubernetes.io/name`. A PVC something else created in the
  namespace (an app whose workload comes from its own chart, say) is not picked
  up unless it carries that label.
- A second selector matches **only this destination's** `PreBackupPod`s (label
  `app.kovostack/backup-destination: <dest>`). Without it, two destinations'
  backups would share one dump Deployment, and whichever finished first would
  delete it under the other.

ReadWriteOnce is handled by K8up. The backup Job is pinned to the node where the
claim is mounted, and on this single-node cluster that is always the node
anyway. Volumes are mounted read-only into the backup Job.

With the annotations unset (`backup` off), the rendered PVCs are byte-identical
to what they were before this feature.

### Destinations, credentials and a second target

`backup.destinations` is a **map**, so adding one is a values change and not a
chart change. Maps merge across values files; lists would not. Each enabled
entry gets its own Schedule, Secret and dump pods. The home Raspberry Pi,
once it exists, is one entry:

```yaml
backup:
  destinations:
    pi:
      url: http://192.168.1.20:8000     # restic rest-server; repo = <url>/<name>/
      store: infisical-backup-pi        # a store scoped to the Pi's credentials
      retention: {keepDaily: 14, keepMonthly: 12}
```

`gateway: {enabled: false}` turns the default one off without deleting it.
`statsURL` (per destination, or `backup.statsURL`) is optional and empty by
default; when set it is passed to the Schedule.

**Credentials** come through `store`, a `ClusterSecretStore` that the **infra
repo owns** (`infisical-backup`, scoped to Infisical `/backup`, non-recursive).
The chart only references it by name, for two reasons:

- Not the shared `infisical` store. It is rooted at `/` and flattens the whole
  project by key name, so a `RESTIC_PASSWORD` anywhere else would collide (see
  [Why each app gets its own store](#why-each-app-gets-its-own-store)).
- Not a store rendered here. Every app's release would render the same
  cluster-scoped object, and ArgoCD would fight over who owns it.

The chart refuses a destination that points at either of those.

The keys are `RESTIC_REST_USERNAME`, `RESTIC_REST_PASSWORD` (the REST server's
basic auth) and `RESTIC_PASSWORD` (repository encryption, shared by all apps).
Each can be renamed per destination with `usernameKey`, `passwordKey` and
`repoPasswordKey`.

⚠️ **The REST username and password must be alphanumeric.** K8up builds
`rest:http://$(USER):$(PASSWORD)@host/…` without escaping, so an `@`, `:`, `/`,
`%`, `?` or `#` in either silently produces a different URL.

⚠️ **Losing `RESTIC_PASSWORD` loses every backup.** The repositories are
encrypted with it and nothing else can open them. Keep a copy outside Infisical
and outside the cluster.

### Schedule

Empty `schedule.*` means a slot derived from `<name>/<dest>`. It is stable
across renders, so there is no ArgoCD drift, and different per app, so the
gateway and the Storage Box's connection limit do not get every app at once:

- backup daily at `00:xx`, `01:xx`, `03:xx` or `04:xx`;
- check on Wednesdays and prune on Sundays, four hours after that.

Cron is read in the operator's time zone, **Europe/Bratislava**. `02:xx` is
skipped because on DST change days it happens twice or not at all. Keep
overrides out of it too. Overriding only `backup` leaves check and prune on
their derived slots, so move those as well if they end up close.

Retention defaults to `keepDaily: 7, keepWeekly: 4, keepMonthly: 6`. A
destination's own `retention` replaces it as a whole.

### SQLite: why a dump pod, and the caveats

A live SQLite file cannot be copied safely. A copy taken mid-write restores as
a corrupt database, and nothing says so until the restore. So:

- Each file in `backup.sqlite.files` is snapshotted with `VACUUM INTO`, which
  writes the database as of one read transaction, taking SQLite's own locks
  alongside the running app. The copy is then `PRAGMA integrity_check`ed, and a
  failure fails the backup.
- **Not `.backup`.** The shell's online backup copies in steps and restarts
  whenever another connection writes in between. Against a busy app it never
  finishes; that was reproduced while building this.
- The dump pod mounts the volume at the **same path and subPath** as the app,
  so the paths in `files` are the app's own. A path on no volume is refused.
- It runs with a pinned `keinos/sqlite3` image (the app images may not contain
  `sqlite3`) **as root**, so it can read a database owned by any uid. Running
  as root, SQLite chowns any `-wal`/`-shm` it creates to the database owner, so
  the app is never locked out of its own files. That is what the `CHOWN`
  capability is kept for; all others except `DAC_OVERRIDE` and `FOWNER` are
  dropped.
- SQLite's locking only works between processes on the **same kernel**. That
  holds for node-local volumes (`local-path`, this cluster). It would not over
  NFS.
- The live file and its `-wal`, `-shm` and `-journal` are **excluded from the
  volume backup** (`k8up.io/backup-restic-args`). A torn copy is worse than
  none. A stale `-wal` restored next to a good database gets replayed into it
  and corrupts it.
- The snapshot in the tar is in rollback-journal mode and owned by root.
  Restore it as described below.

### Postgres: how it connects, and the caveats

The dump pod gets the app's own environment: its synced Secret via `envFrom`
and everything in `env:`. It connects the way the app does, through the
`externalServices` name (`postgres` → 172.17.0.1). You name the variables:

| value | meaning |
|---|---|
| `urlEnv` | a URL: `postgres://`, `postgresql://` or `jdbc:postgresql://`. For JDBC, `jdbc:` and the `?query` are stripped (JDBC parameters are not libpq's). Credentials inside a `postgres://` URL are used as they are |
| `hostEnv`, `portEnv`, `databaseEnv`, `userEnv`, `passwordEnv` | the parts, exported as `PGHOST` … `PGPASSWORD` |
| `env` | literal `PG*` variables for what the app has nowhere, e.g. `{PGDATABASE: scraper}` |

A named variable that is empty or unset fails the backup. It never falls back
to a default user or database. Names are validated at render time, since they
end up in a shell script.

- **The client's major version must be at least the server's.** pg_dump
  refuses a server newer than itself. The platform's Postgres is **17**, so the
  default client is the pinned `postgres:17.11-alpine`, overridable with
  `backup.postgres.image`/`imageTag`. When the server is upgraded, raise this
  in step. Keep the majors equal rather than going ahead: a newer pg_dump's
  output is only guaranteed to load into a server at least as new as itself.
- `format: plain` (default) gives SQL, restored with `psql`, which deduplicates
  well in restic. `custom` gives a `pg_restore` archive, for selective restores.
- The dump pod runs as uid 70 (postgres in the alpine image) with every
  capability dropped.

### Restoring

Stop the writer first for anything that is a database. **Do it in git**: set
`replicas: 0` in the app's values. A `kubectl scale` is undone by ArgoCD's
self-heal within minutes. Uploads can be restored with the app running.

**Plain restic CLI** works from anywhere that can reach the gateway, and needs
nothing from K8up:

```bash
kubectl -n backup port-forward svc/restic-gateway 8080:8080 &
export RESTIC_REPOSITORY=rest:http://<RESTIC_REST_USERNAME>:<RESTIC_REST_PASSWORD>@localhost:8080/<name>/
export RESTIC_PASSWORD=<RESTIC_PASSWORD>          # from Infisical /backup

restic snapshots                                   # one per volume + one per dump, per night
restic ls latest --path /data/<name>-uploads       # browse a volume snapshot

# a volume, into a local directory
restic restore latest --path /data/<name>-uploads --target ./restore

# SQLite: the tar holds the files at the paths the app sees
restic dump latest --path /<name>-sqlite.tar /<name>-sqlite.tar | tar -x -C ./restore

# Postgres: into a freshly created, empty database
restic dump latest --path /<name>-postgres.sql /<name>-postgres.sql \
  | docker exec -i postgres psql -v ON_ERROR_STOP=1 -U <user> -d <db>
```

A plain dump has no `DROP` statements. Restore into an empty database (drop and
recreate it, owned by the app's user) rather than on top of the live one.

**A K8up `Restore` object** writes a snapshot straight into a PVC, in-cluster.
It picks the latest snapshot matching `paths` (or an explicit `snapshot` ID),
and puts its contents at the claim's root:

```yaml
apiVersion: k8up.io/v1
kind: Restore
metadata:
  name: uploads-2026-09-30
  namespace: <name>
spec:
  paths: ["/data/<name>-uploads"]      # or: snapshot: <id from `restic snapshots`>
  restoreMethod:
    folder:
      claimName: <name>-uploads        # or a fresh claim, to inspect before swapping
  backend:
    repoPasswordSecretRef: {name: <name>-backup-gateway, key: RESTIC_PASSWORD}
    rest:
      url: http://restic-gateway.backup.svc.cluster.local:8080/<name>/
      userSecretRef:     {name: <name>-backup-gateway, key: RESTIC_REST_USERNAME}
      passwordSecretReg: {name: <name>-backup-gateway, key: RESTIC_REST_PASSWORD}
```

Apply it by hand, since it is a one-off action and not desired state, then
delete it once `kubectl -n <name> get restore` shows it finished. Pointed at
`paths: ["/<name>-sqlite.tar"]`, the same object drops the tar into the claim.

**After restoring a SQLite database**, with the app stopped:

1. Delete any `<db>-wal`, `<db>-shm` and `<db>-journal` next to it. A stale WAL
   is replayed into the restored file.
2. Put the restored file in place.
3. `chown` it to the app's uid, since the snapshot is owned by root.
4. Start the app again.

The restored file is in rollback-journal mode. An app that wants WAL normally
sets it when it connects. If yours does not, run `PRAGMA journal_mode=WAL;`
once.

## Local rendering

```bash
helm template whoami charts/app -f applications/whoami/values.yaml
```

Worth doing before every push. A values key this chart does not define is
silently ignored, exactly as with the upstream charts in `infrastructure/`.