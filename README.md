# kovostack-helm-charts

Helm charts for apps running in Kubernetes cluster. Consumed by
[kovostack-infra-gitops](https://github.com/Kovospace/kovostack-infra-gitops),
which holds the Applications and their values.

```
charts/
  app/      convention-driven chart for workloads — see charts/app/README.md
```

## Why these live outside the GitOps repo

So that Applications can **pin a chart version**. ArgoCD rejects a multi-source
Application that references two revisions of the same repository, and the values
source has to stay on `main` for CI deploys to take effect:

```
cannot reference a different revision of the same repository
```

With the chart in its own repository the two sources are unrelated, and an
Application can track a chart tag while its values track `main`:

```yaml
sources:
  - repoURL: git@github.com:Kovospace/kovostack-helm-charts.git
    targetRevision: chart-app-1.1.0          # pinned
    path: charts/app
    helm:
      valueFiles:
        - $values/applications/nsr/values.yaml
        - $values/versions/nsr.yaml
  - repoURL: git@github.com:Kovospace/kovostack-infra-gitops.git
    targetRevision: main                      # values stay live
    ref: values
```

A chart change now reaches one app at a time, when you choose. Before this,
every app tracked the chart at `main`, and a single bad annotation broke all of
them at once.

## Releasing

Tag convention: **`chart-<chart_name>-<semver>`**, matching `version:` in the
chart's `Chart.yaml`.

```bash
# bump version: in charts/app/Chart.yaml, then
git commit -am "app: <what changed>"
git tag chart-app-1.2.0
git push && git push --tags
```

Then raise `targetRevision` in the consuming Applications **one at a time** —
staging the rollout is the entire point of pinning.

Render before tagging; a values key the chart does not define is silently
ignored, so nothing will tell you it was wrong:

```bash
helm template test charts/app --set name=test --set image=nginx
```

## The chart agent

`helm-chart-devops` is a Claude Code subagent that owns chart edits: it makes the
change, bumps `version:` in that chart's `Chart.yaml`, renders it, and delivers
the result as a PR from an `upgrade/**` branch. It never pushes to `main` and
never tags — tagging stays the human release step above.

```
.claude/agents/helm-chart-devops.md    the agent (symlinked into ~/.claude/agents/)
.claude/hooks/branch-guard.sh          PreToolUse hook enforcing the branch rule
.claude/settings.json                  wires the hook up for this repo
```

### Bump size

| | when |
|---|---|
| patch | fix, refactor, docs — nothing an existing app renders changes shape |
| minor | new value, new template, new switch, changed default |
| major | never — the agent stops and asks, because every pinned Application would need coordinated attention |

### Triggering it from another project

The agent is symlinked into `~/.claude/agents/`, so it is available from every
repository on this machine, not just this one. From an app repo or from
`kovostack-infra-gitops`:

```
> use the helm-chart-devops agent to add a nodeSelector value to charts/app
```

or non-interactively, from a script or CI step in that project:

```bash
claude -p "Use the helm-chart-devops subagent: charts/app needs a nodeSelector value"
```

It resolves this repository itself — `$KOVOSTACK_CHARTS_REPO` if set, otherwise
`/home/kovo/IdeaProjects/kovostack-helm-charts`, otherwise a fresh clone — so the
calling project's own files are never touched. For the first two to work, the
calling project has to let the agent out of its own directory:

```json
// <other-project>/.claude/settings.json
{ "permissions": { "additionalDirectories": ["/home/kovo/IdeaProjects/kovostack-helm-charts"] } }
```

Without that, the agent clones instead, and the branch it pushes is still the
deliverable — only the local checkout differs.

### The branch guard

`branch-guard.sh` is a `PreToolUse` hook on `Bash`. It parses the command,
resolves which remote the push is aimed at, and denies anything landing outside
`upgrade/**` in this repository — `main`, a tag, `--tags`, `--all`, `--mirror`,
`HEAD:main`, a deletion, or a bare `git push` while on `main`. It resolves the
remote first and exits silently for every other repository, which is why it is
safe to install in `~/.claude/settings.json` as well as here — that global copy
is what keeps the rule in force when the agent is triggered from another project,
since a project's own settings do not travel with it.

It guards a human's `git push` in this repo too. That is deliberate: `main` moves
by PR merge, and tags are cut from `main` afterwards.

## Access

ArgoCD needs read access to this repository, and a GitHub deploy key can only be
registered on **one** repo — so this needs its own key, separate from the one
the GitOps repo uses.

```bash
ssh-keygen -t ed25519 -C argocd@kovostack-charts -f ~/.ssh/argocd-charts-key -N ''
# add the .pub under Settings → Deploy keys here, read-only

kubectl -n argocd create secret generic repo-kovostack-helm-charts \
  --from-literal=type=git \
  --from-literal=url=git@github.com:Kovospace/kovostack-helm-charts.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd-charts-key
kubectl -n argocd label secret repo-kovostack-helm-charts \
  argocd.argoproj.io/secret-type=repository
```

The key must have no passphrase — ArgoCD has no ssh-agent and cannot prompt.

## History

The chart was developed in `kovostack-infra-gitops` under `charts/app` until
2026-08-06; its history up to `chart-app-1.1.0` is in that repository.
