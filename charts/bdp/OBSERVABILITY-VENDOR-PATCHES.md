# Observability image pinning (Task G1)

Extends the digest-pin manifest introduced for the platform/postgresql/redis/
keycloak/cert-manager images to the observability stack vendored in Task E1
(kube-prometheus-stack 87.19.2 + Loki 7.1.0, decompressed under
`charts/bdp/charts/` — gitignored, working-tree only).

## No subchart template patches required

Unlike the brief's initial assumption, **no files under `charts/bdp/charts/`
were modified.** Following the same pattern already established for
postgresql/redis/keycloak/cert-manager: every image is pinned by setting
each subchart's own native `image.{registry,repository,tag,sha|digest}`
override keys directly in `charts/bdp/values.yaml` — not by patching
templates. `global.azure.images` (also updated, see below) is a separate,
parallel manifest that exists purely for `cpa verify`'s static scan; it is
not consumed at render time by these subcharts.

This means the build host in Task G2 needs nothing beyond a fresh
`helm pull --untar` of the two charts at the pinned versions — the parent
`values.yaml` (committed to git) reproduces the full pin without any manual
patch step.

## Field-name inconsistency across subcharts (read before editing further)

Each vendored (sub-)chart names its digest override field differently, and
some require the raw hex while others require the full `sha256:` string.
Getting this wrong renders silently (no digest suffix) or breaks the render
(malformed image ref) rather than erroring cleanly — verify against the
actual named template, not the field name alone, when adding future images.

| Chart / key path | Digest field | Format | Notes |
|---|---|---|---|
| `kube-prometheus-stack.prometheusOperator.image` | `sha` | bare hex | template adds `@sha256:` |
| `kube-prometheus-stack.prometheusOperator.prometheusConfigReloader.image` | `sha` | bare hex | |
| `kube-prometheus-stack.prometheusOperator.admissionWebhooks.patch.image` | `sha` | bare hex | `tag` has **no default** — must be set explicitly |
| `kube-prometheus-stack.alertmanager.alertmanagerSpec.image` | `sha` | bare hex | |
| `kube-prometheus-stack.prometheus.prometheusSpec.image` | `sha` | bare hex | |
| `kube-prometheus-stack.grafana.image` / `.sidecar.image` | `sha` | bare hex | |
| `kube-prometheus-stack.kube-state-metrics.image` | `sha` | **full `sha256:...`** | this chart's helper does NOT add the prefix — inconsistent with the others above |
| `kube-prometheus-stack.prometheus-node-exporter.image` | `digest` | full `sha256:...` | field is named `digest`, not `sha`; also see distroless note below |
| `kube-prometheus-stack.crds.upgradeJob.image.kubectl` | `sha` | bare hex | `tag` has no default — pins to the running cluster's own k8s version otherwise |
| `kube-prometheus-stack.crds.upgradeJob.image.busybox` | `sha` | bare hex | **ineffective** — see known gap below |
| `loki.loki.image`, `loki.test.image`, `loki.lokiCanary.image`, `loki.gateway.image`, `loki.memcached.image`, `loki.memcachedExporter.image` | `digest` | full `sha256:...` | shared `loki.baseImage` helper |
| `loki.sidecar.image` | `sha` | bare hex | same helper, accepts either field |

## Known gaps (documented, not fixed — out of scope for a values-only pin)

- **`crds.upgradeJob.image.busybox`**: this vendored chart's own
  `templates/upgrade/job.yaml` guards the digest suffix on
  `.Values.upgradeJob.image.sha` (a top-level key that doesn't exist) instead
  of `.busybox.sha` — an upstream template bug. Busybox is mirrored to ACR
  and pinned by **tag only** (`tools/busybox:latest`); the `sha` value set
  in values.yaml is harmless but never read by this template. Since we
  exclusively control that ACR tag, this is a low-risk gap, not a template
  patch target for this task.
- **`--thanos-default-base-image=quay.io/thanos/thanos:v0.42.2`**: a
  CLI-arg default on the operator deployment for a ThanosRuler/Prometheus
  thanos-sidecar feature that is **not enabled** anywhere in this chart
  (no `ThanosRuler` resource, no `thanosSpec` set) — dormant, never pulled
  at runtime. Left unmirrored; flag if thanos is ever turned on later.
- **`--acme-http01-solver-image=quay.io/jetstack/cert-manager-acmesolver:v1.15.3`**
  (cert-manager deployment, `charts/bdp/charts/cert-manager/templates/deployment.yaml:109`):
  pre-existing gap, **unrelated to this task** — cert-manager's own
  `acmesolver.image` override was never set when cert-manager was pinned.
  Confirmed present at `ef0c014` already; not introduced or fixed here.
  Worth a follow-up task.
- **The Prometheus/Alertmanager container images themselves are not
  present in a static `helm template` render** — the operator injects them
  into StatefulSets it creates from the `Prometheus`/`Alertmanager` CRs at
  runtime, using the `prometheus.prometheusSpec.image` /
  `alertmanager.alertmanagerSpec.image` values above. Same for the
  `config-reloader` sidecar (injected via the `--prometheus-config-reloader=`
  CLI arg on the operator, confirmed resolving to
  `bdpmarketplace.azurecr.io/tools/prometheus-config-reloader:v0.92.1@sha256:bf6f3527...`
  in the render). A plain `grep image:` check does **not** catch these —
  verify the operator deployment's args too.

## Container-name → image mapping

See `global.azure.images` in `charts/bdp/values.yaml` (Task G1 section) and
the full report at
`bdp-platform/.superpowers/sdd/2026-07-26-persistence-observability/task-G1-report.md`
for the complete mirrored-image table and container-name key mapping.
