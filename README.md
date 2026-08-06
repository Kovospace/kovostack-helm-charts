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
