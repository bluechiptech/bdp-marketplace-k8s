# Observability image pinning (Task G1)

Extends the digest-pin manifest introduced for the platform/postgresql/redis/
keycloak/cert-manager images to the observability stack vendored in Task E1
(kube-prometheus-stack 87.19.2 + Loki 7.1.0, decompressed under
`charts/bdp/charts/` — gitignored, working-tree only).

## Correction (fix round 1)

An earlier revision of this document claimed no subchart template changes
were needed, reasoning that setting each subchart's own native
`image.{registry,repository,tag,sha|digest}` values produced the identical
rendered string as the already-passing postgresql/redis/cert-manager
entries, so that must be the mechanism. **That reasoning was wrong.**
`cpa verify` is source-aware: it inspects which values path a template's
`image:` line actually reads, not just the resulting string. Proof, found
in this repo before touching anything:
`postgresql/templates/primary/statefulset.yaml:179`,
`redis/templates/master/application.yaml:105`, and all four
`cert-manager/templates/*.yaml` files read
`{{ .Values.global.azure.images.<key>.registry }}/...@{{ ...digest }}` (or
`(index .Values.global.azure.images "cert-manager-cainjector")` for keys
with dashes) **directly** — that direct read is why those pass, not the
matching string. The native `image.*` values these subcharts also carry
(and which this task's values.yaml additions from round 1 still set) are
now vestigial for the `image:` line itself; they're only still consumed for
`imagePullPolicy` and, in a couple of spots, a `version:`/`tag:` display
field — same as the cert-manager precedent.

This round patches every vendored kube-prometheus-stack + Loki template so
each container's `image:` line reads `.Values.global.azure.images.<key>`
(or `(index .Values.global.azure.images "key-with-dashes")`) directly,
matching the cert-manager idiom exactly.

## Patched files (working-tree only, gitignored — reproduce on the G2 build host)

### `charts/bdp/charts/kube-prometheus-stack/templates/prometheus-operator/deployment.yaml`

Operator's own image (container name `kube-prometheus-stack` — this chart
names the container after itself, not `prometheus-operator`):

```diff
-          {{- $configReloaderRegistry := .Values.global.imageRegistry | default .Values.prometheusOperator.prometheusConfigReloader.image.registry -}}
-          {{- $operatorRegistry := .Values.global.imageRegistry | default .Values.prometheusOperator.image.registry -}}
           {{- $thanosRegistry := .Values.global.imageRegistry | default .Values.prometheusOperator.thanosImage.registry -}}
-          {{- if .Values.prometheusOperator.image.sha }}
-          image: "{{ $operatorRegistry }}/{{ .Values.prometheusOperator.image.repository }}:{{ .Values.prometheusOperator.image.tag | default .Chart.AppVersion }}@sha256:{{ .Values.prometheusOperator.image.sha }}"
-          {{- else }}
-          image: "{{ $operatorRegistry }}/{{ .Values.prometheusOperator.image.repository }}:{{ .Values.prometheusOperator.image.tag | default .Chart.AppVersion }}"
-          {{- end }}
+          image: "{{ (index .Values.global.azure.images "kube-prometheus-stack").registry }}/{{ (index .Values.global.azure.images "kube-prometheus-stack").image }}@{{ (index .Values.global.azure.images "kube-prometheus-stack").digest }}"
           imagePullPolicy: "{{ .Values.prometheusOperator.image.pullPolicy }}"
```

The `config-reloader` sidecar the operator injects into every managed
Prometheus/Alertmanager pod (passed as a CLI arg, invisible to a plain
`grep image:` scan of a static render):

```diff
-            {{- if .Values.prometheusOperator.prometheusConfigReloader.image.sha }}
-            - --prometheus-config-reloader={{ $configReloaderRegistry }}/{{ .Values.prometheusOperator.prometheusConfigReloader.image.repository }}:{{ .Values.prometheusOperator.prometheusConfigReloader.image.tag | default .Chart.AppVersion }}@sha256:{{ .Values.prometheusOperator.prometheusConfigReloader.image.sha }}
-            {{- else }}
-            - --prometheus-config-reloader={{ $configReloaderRegistry }}/{{ .Values.prometheusOperator.prometheusConfigReloader.image.repository }}:{{ .Values.prometheusOperator.prometheusConfigReloader.image.tag | default .Chart.AppVersion }}
-            {{- end }}
+            - --prometheus-config-reloader={{ (index .Values.global.azure.images "config-reloader").registry }}/{{ (index .Values.global.azure.images "config-reloader").image }}@{{ (index .Values.global.azure.images "config-reloader").digest }}
```

### `.../templates/prometheus-operator/admission-webhooks/job-patch/job-createSecret.yaml`

Container `create`:

```diff
         - name: create
-          {{- $registry := .Values.global.imageRegistry | default .Values.prometheusOperator.admissionWebhooks.patch.image.registry -}}
-          {{- if .Values.prometheusOperator.admissionWebhooks.patch.image.sha }}
-          image: {{ $registry }}/{{ .Values.prometheusOperator.admissionWebhooks.patch.image.repository }}:{{ .Values.prometheusOperator.admissionWebhooks.patch.image.tag }}@sha256:{{ .Values.prometheusOperator.admissionWebhooks.patch.image.sha }}
-          {{- else }}
-          image: {{ $registry }}/{{ .Values.prometheusOperator.admissionWebhooks.patch.image.repository }}:{{ .Values.prometheusOperator.admissionWebhooks.patch.image.tag }}
-          {{- end }}
+          image: {{ (index .Values.global.azure.images "create").registry }}/{{ (index .Values.global.azure.images "create").image }}@{{ (index .Values.global.azure.images "create").digest }}
           imagePullPolicy: {{ .Values.prometheusOperator.admissionWebhooks.patch.image.pullPolicy }}
```

### `.../templates/prometheus-operator/admission-webhooks/job-patch/job-patchWebhook.yaml`

Container `patch` — identical shape, keyed `"patch"` instead of `"create"`
(same source image, different container name, per the cainjector-lesson
rule that same-image containers with different names still get their own
manifest key).

### `charts/bdp/charts/kube-prometheus-stack/charts/crds/templates/upgrade/job.yaml`

Containers `busybox` (initContainer) and `kubectl`. This also **fixes a
real upstream bug**: the busybox block guarded the digest suffix on
`.Values.upgradeJob.image.sha` — a top-level key that doesn't exist (should
have been `.busybox.sha`) — so busybox never got digest-pinned no matter
what was set in values. Patching straight to the manifest entry sidesteps
that bug entirely:

```diff
         - name: busybox
-          {{- $busyboxRegistry := .Values.global.imageRegistry | default .Values.upgradeJob.image.busybox.registry -}}
-          {{- if .Values.upgradeJob.image.sha }}
-          image: "{{ $busyboxRegistry }}/{{ .Values.upgradeJob.image.busybox.repository }}:{{ .Values.upgradeJob.image.busybox.tag }}@sha256:{{ .Values.upgradeJob.image.busybox.sha }}"
-          {{- else }}
-          image: "{{ $busyboxRegistry }}/{{ .Values.upgradeJob.image.busybox.repository }}:{{ .Values.upgradeJob.image.busybox.tag }}"
-          {{- end }}
+          image: "{{ (index .Values.global.azure.images "busybox").registry }}/{{ (index .Values.global.azure.images "busybox").image }}@{{ (index .Values.global.azure.images "busybox").digest }}"
           imagePullPolicy: "{{ .Values.upgradeJob.image.busybox.pullPolicy }}"
```

```diff
         - name: kubectl
-          {{- $kubectlRegistry := .Values.global.imageRegistry | default .Values.upgradeJob.image.kubectl.registry -}}
-          {{- $defaultKubernetesVersion := (ternary (printf "%s.0" .Capabilities.KubeVersion.Version) (regexFind "v\\d+\\.\\d+\\.\\d+" .Capabilities.KubeVersion.Version) (regexMatch "^v\\d+\\.\\d+$" .Capabilities.KubeVersion.Version)) -}}
-          {{- if .Values.upgradeJob.image.kubectl.sha }}
-          image: "{{ $kubectlRegistry }}/{{ .Values.upgradeJob.image.kubectl.repository }}:{{ .Values.upgradeJob.image.kubectl.tag | default $defaultKubernetesVersion }}@sha256:{{ .Values.upgradeJob.image.kubectl.sha }}"
-          {{- else }}
-          image: "{{ $kubectlRegistry }}/{{ .Values.upgradeJob.image.kubectl.repository }}:{{ .Values.upgradeJob.image.kubectl.tag | default $defaultKubernetesVersion }}"
-          {{- end }}
+          image: "{{ (index .Values.global.azure.images "kubectl").registry }}/{{ (index .Values.global.azure.images "kubectl").image }}@{{ (index .Values.global.azure.images "kubectl").digest }}"
           imagePullPolicy: "{{ .Values.upgradeJob.image.kubectl.pullPolicy }}"
```

### `charts/bdp/charts/kube-prometheus-stack/templates/prometheus/prometheus.yaml`

The `Prometheus` CR's `spec.image` (operator injects this into the
StatefulSet it manages; container name is operator-hardcoded to
`prometheus`):

```diff
 {{- if .Values.prometheus.prometheusSpec.image }}
-  {{- $registry := .Values.global.imageRegistry | default .Values.prometheus.prometheusSpec.image.registry -}}
-  {{- $tag := (.Values.prometheus.prometheusSpec.image.tag | empty | not) | ternary (printf ":%s" .Values.prometheus.prometheusSpec.image.tag) "" -}}
-  {{- $sha := (.Values.prometheus.prometheusSpec.image.sha | empty | not) | ternary (printf "@sha256:%s" .Values.prometheus.prometheusSpec.image.sha) "" }}
-  image: "{{ printf "%s/%s%s%s" $registry .Values.prometheus.prometheusSpec.image.repository $tag $sha }}"
+  image: "{{ (index .Values.global.azure.images "prometheus").registry }}/{{ (index .Values.global.azure.images "prometheus").image }}@{{ (index .Values.global.azure.images "prometheus").digest }}"
   imagePullPolicy: "{{ .Values.prometheus.prometheusSpec.image.pullPolicy }}"
   version: "{{ default .Values.prometheus.prometheusSpec.image.tag .Values.prometheus.prometheusSpec.version }}"
 {{- end }}
```

### `charts/bdp/charts/kube-prometheus-stack/templates/alertmanager/alertmanager.yaml`

The `Alertmanager` CR's `spec.image` (container name operator-hardcoded to
`alertmanager`):

```diff
 {{- if .Values.alertmanager.alertmanagerSpec.image }}
-  {{- $registry := .Values.global.imageRegistry | default .Values.alertmanager.alertmanagerSpec.image.registry -}}
-  {{- if and .Values.alertmanager.alertmanagerSpec.image.tag .Values.alertmanager.alertmanagerSpec.image.sha }}
-  image: "{{ $registry }}/{{ .Values.alertmanager.alertmanagerSpec.image.repository }}:{{ .Values.alertmanager.alertmanagerSpec.image.tag }}@sha256:{{ .Values.alertmanager.alertmanagerSpec.image.sha }}"
-  {{- else if .Values.alertmanager.alertmanagerSpec.image.sha }}
-  image: "{{ $registry }}/{{ .Values.alertmanager.alertmanagerSpec.image.repository }}@sha256:{{ .Values.alertmanager.alertmanagerSpec.image.sha }}"
-  {{- else if .Values.alertmanager.alertmanagerSpec.image.tag }}
-  image: "{{ $registry }}/{{ .Values.alertmanager.alertmanagerSpec.image.repository }}:{{ .Values.alertmanager.alertmanagerSpec.image.tag }}"
-  {{- else }}
-  image: "{{ $registry }}/{{ .Values.alertmanager.alertmanagerSpec.image.repository }}"
-  {{- end }}
+  image: "{{ (index .Values.global.azure.images "alertmanager").registry }}/{{ (index .Values.global.azure.images "alertmanager").image }}@{{ (index .Values.global.azure.images "alertmanager").digest }}"
   imagePullPolicy: "{{ .Values.alertmanager.alertmanagerSpec.image.pullPolicy }}"
```

### `charts/bdp/charts/kube-prometheus-stack/charts/kube-state-metrics/templates/_helpers.tpl`

Redefined the `kube-state-metrics.image` named template wholesale (single
call site: `templates/deployment.yaml:167`):

```diff
 {{- define "kube-state-metrics.image" -}}
-{{- if .Values.image.sha }}
-{{- if .Values.global.imageRegistry }}
-{{- printf "%s/%s:%s@%s" .Values.global.imageRegistry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) .Values.image.sha }}
-{{- else }}
-{{- printf "%s/%s:%s@%s" .Values.image.registry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) .Values.image.sha }}
-{{- end }}
-{{- else }}
-{{- if .Values.global.imageRegistry }}
-{{- printf "%s/%s:%s" .Values.global.imageRegistry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) }}
-{{- else }}
-{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) }}
-{{- end }}
-{{- end }}
+{{- printf "%s/%s@%s" (index .Values.global.azure.images "kube-state-metrics").registry (index .Values.global.azure.images "kube-state-metrics").image (index .Values.global.azure.images "kube-state-metrics").digest }}
 {{- end }}
```

### `charts/bdp/charts/kube-prometheus-stack/charts/prometheus-node-exporter/templates/_helpers.tpl`

Redefined `prometheus-node-exporter.image` wholesale (call sites:
`templates/daemonset.yaml:100,234`). This also sidesteps the
`image.distroless: true` default this chart's own parent values set — that
flag makes the old helper append `-distroless` a second time if the tag
already contains it, an easy way to reintroduce the
`v1.12.1-distroless-distroless` bug seen during round 1 if this file is
ever hand-edited again:

```diff
 {{- define "prometheus-node-exporter.image" -}}
-{{- if .Values.image.sha }}
-{{- fail "image.sha forbidden. Use image.digest instead" }}
-{{- else if .Values.image.digest }}
-{{- if .Values.global.imageRegistry }}
-{{- printf "%s/%s:%s%s@%s" .Values.global.imageRegistry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) (ternary "-distroless" "" .Values.image.distroless) .Values.image.digest }}
-{{- else }}
-{{- printf "%s/%s:%s%s@%s" .Values.image.registry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) (ternary "-distroless" "" .Values.image.distroless) .Values.image.digest }}
-{{- end }}
-{{- else }}
-{{- if .Values.global.imageRegistry }}
-{{- printf "%s/%s:%s%s" .Values.global.imageRegistry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) (ternary "-distroless" "" .Values.image.distroless) }}
-{{- else }}
-{{- printf "%s/%s:%s%s" .Values.image.registry .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) (ternary "-distroless" "" .Values.image.distroless) }}
-{{- end }}
-{{- end }}
+{{- printf "%s/%s@%s" (index .Values.global.azure.images "node-exporter").registry (index .Values.global.azure.images "node-exporter").image (index .Values.global.azure.images "node-exporter").digest }}
 {{- end }}
```

### `charts/bdp/charts/kube-prometheus-stack/charts/grafana/templates/_pod.tpl`

Three containers patched in place (this file repeats the sidecar-image
block 9 times for every sidecar type grafana supports; only
`sc-dashboard` and `sc-datasources` are enabled in this chart's values, so
only those two plus the main `grafana` container were patched — the seven
disabled sidecar blocks, dead code for this deployment, are untouched):

```diff
   - name: grafana
-    {{- $registry := .Values.global.imageRegistry | default .Values.image.registry -}}
-    {{- if .Values.image.sha }}
-    image: "{{ $registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}@sha256:{{ .Values.image.sha }}"
-    {{- else }}
-    image: "{{ $registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
-    {{- end }}
+    image: "{{ (index .Values.global.azure.images "grafana").registry }}/{{ (index .Values.global.azure.images "grafana").image }}@{{ (index .Values.global.azure.images "grafana").digest }}"
     imagePullPolicy: {{ .Values.image.pullPolicy }}
```

```diff
   - name: {{ include "grafana.name" . }}-sc-dashboard
-    {{- $registry := .Values.global.imageRegistry | default .Values.sidecar.image.registry -}}
-    {{- if .Values.sidecar.image.sha }}
-    image: "{{ $registry }}/{{ .Values.sidecar.image.repository }}:{{ .Values.sidecar.image.tag }}@sha256:{{ .Values.sidecar.image.sha }}"
-    {{- else }}
-    image: "{{ $registry }}/{{ .Values.sidecar.image.repository }}:{{ .Values.sidecar.image.tag }}"
-    {{- end }}
+    image: "{{ (index .Values.global.azure.images "grafana-sc-dashboard").registry }}/{{ (index .Values.global.azure.images "grafana-sc-dashboard").image }}@{{ (index .Values.global.azure.images "grafana-sc-dashboard").digest }}"
     imagePullPolicy: {{ .Values.sidecar.imagePullPolicy }}
```

Same shape for `-sc-datasources`, keyed `"grafana-sc-datasources"`.

### `charts/bdp/charts/loki/templates/_helpers.tpl`

Redefined `loki.lokiImage` (main `loki` container; feeds `loki.image`,
called from `templates/single-binary/statefulset.yaml:94`):

```diff
 {{- define "loki.lokiImage" -}}
-{{- $dict := dict "service" .Values.loki.image "global" .Values.global "defaultVersion" .Chart.AppVersion -}}
-{{- include "loki.baseImage" $dict -}}
+{{- printf "%s/%s@%s" (index .Values.global.azure.images "loki").registry (index .Values.global.azure.images "loki").image (index .Values.global.azure.images "loki").digest -}}
 {{- end -}}
```

(`loki.memcachedImage` / `loki.memcachedExporterImage`, also defined in
this file, are dead code — never called anywhere; the real memcached/
memcached-exporter image lines live in `_memcached-statefulset.tpl` below
and call `loki.baseImage` directly with their own inline dict. Left alone.)

### `charts/bdp/charts/loki/templates/single-binary/statefulset.yaml`

Container `loki-sc-rules`:

```diff
         - name: loki-sc-rules
-          {{- $dict := dict "service" .Values.sidecar.image "global" .Values.global }}
-          image: {{ include "loki.baseImage" $dict }}
+          image: "{{ (index .Values.global.azure.images "loki-sc-rules").registry }}/{{ (index .Values.global.azure.images "loki-sc-rules").image }}@{{ (index .Values.global.azure.images "loki-sc-rules").digest }}"
           imagePullPolicy: {{ .Values.sidecar.image.pullPolicy }}
```

### `charts/bdp/charts/loki/templates/memcached/_memcached-statefulset.tpl`

Shared by both `chunks-cache` and `results-cache` StatefulSets. Containers
`memcached` and `exporter`:

```diff
         - name: memcached
-          {{- $dict := dict "service" $.ctx.Values.memcached.image "global" $.ctx.Values.global }}
-          image: {{ include "loki.baseImage" $dict }}
+          image: "{{ (index $.ctx.Values.global.azure.images "memcached").registry }}/{{ (index $.ctx.Values.global.azure.images "memcached").image }}@{{ (index $.ctx.Values.global.azure.images "memcached").digest }}"
           imagePullPolicy: {{ $.ctx.Values.memcached.image.pullPolicy }}
```

```diff
         - name: exporter
-          {{- $dict := dict "service" $.ctx.Values.memcachedExporter.image "global" $.ctx.Values.global }}
-          image: {{ include "loki.baseImage" $dict }}
+          image: "{{ (index $.ctx.Values.global.azure.images "exporter").registry }}/{{ (index $.ctx.Values.global.azure.images "exporter").image }}@{{ (index $.ctx.Values.global.azure.images "exporter").digest }}"
           imagePullPolicy: {{ $.ctx.Values.memcachedExporter.image.pullPolicy }}
```

Note the `$.ctx.Values` prefix (not `.Values`) — this template is `include`d
with a wrapped context dict; `global` still propagates through it.

### `charts/bdp/charts/loki/templates/loki-canary/_helpers.tpl`

Redefined `loki-canary.image`:

```diff
 {{- define "loki-canary.image" -}}
-{{- $dict := dict "service" .Values.lokiCanary.image "global" .Values.global "defaultVersion" .Chart.AppVersion -}}
-{{- include "loki.baseImage" $dict -}}
+{{- printf "%s/%s@%s" (index .Values.global.azure.images "loki-canary").registry (index .Values.global.azure.images "loki-canary").image (index .Values.global.azure.images "loki-canary").digest -}}
 {{- end -}}
```

### `charts/bdp/charts/loki/templates/gateway/_helpers-gateway.tpl`

Redefined `loki.gatewayImage` (container `nginx`):

```diff
 {{- define "loki.gatewayImage" -}}
-{{- $dict := dict "service" .Values.gateway.image "global" .Values.global -}}
-{{- include "loki.baseImage" $dict -}}
+{{- printf "%s/%s@%s" (index .Values.global.azure.images "nginx").registry (index .Values.global.azure.images "nginx").image (index .Values.global.azure.images "nginx").digest -}}
 {{- end }}
```

### `charts/bdp/charts/loki/templates/tests/_helpers.tpl`

Redefined `loki.helmTestImage` (container `loki-helm-test`, a `helm.sh/hook:
test` Pod — still rendered by plain `helm template`, not filtered like a
real `helm test` invocation):

```diff
 {{- define "loki.helmTestImage" -}}
-{{- $dict := dict "service" .Values.test.image "global" .Values.global "defaultVersion" .Chart.AppVersion -}}
-{{- include "loki.baseImage" $dict -}}
+{{- printf "%s/%s@%s" (index .Values.global.azure.images "loki-helm-test").registry (index .Values.global.azure.images "loki-helm-test").image (index .Values.global.azure.images "loki-helm-test").digest -}}
 {{- end -}}
```

## Not patched (out of scope — confirmed dormant for this chart's config)

- `templates/backend/statefulset-backend.yaml`, `templates/ruler/statefulset-ruler.yaml`,
  `templates/provisioner/_helpers.yaml`, `templates/single-binary/statefulset-recreate-job.yaml`
  (Loki): SimpleScalable-mode backend/ruler targets and the provisioner are
  zeroed to `replicas: 0` / disabled in this chart's values (`write.replicas:
  0`, `read.replicas: 0`, `backend.replicas: 0`, single-binary deployment
  mode only) — none of these templates render for this configuration, so
  they never reach `cpa verify`'s scan. Flag if the deployment mode ever
  changes.
- `--thanos-default-base-image=quay.io/thanos/thanos:v0.42.2` (operator CLI
  arg default): no `ThanosRuler` resource and no `prometheusSpec.thanos`
  block anywhere in this chart's values — dormant, never pulled.
- `prometheus-operator/templates/prometheus-operator/deployment.yaml`'s
  `admissionWebhooks.deployment.image` (`prometheus-operator/admission-webhook`):
  the alternate built-in-webhook-server mode, disabled in favor of the
  `kube-webhook-certgen` create/patch Jobs pattern already pinned above.
- `cert-manager`'s `--acme-http01-solver-image=quay.io/jetstack/cert-manager-acmesolver:v1.15.3`:
  pre-existing gap from before this task (confirmed present already at
  `ef0c014`), unrelated to observability. Worth a follow-up task, not fixed
  here.

## Verification

`helm template t charts/bdp --set observability.enabled=true | grep "image:"`
→ every line `bdpmarketplace.azurecr.io/...@sha256:...`, zero
docker.io/quay.io/ghcr.io/registry.k8s.io references, `busybox` now
digest-pinned (round-1 gap fixed).

Structural proof of sourcing (not string coincidence): temporarily changed
only the `digest:` value in `global.azure.images` for three representative
entries (`prometheus`, `kube-state-metrics`, `loki` — one CR-injected
field, one named-helper-driven subchart, one Loki-native template) to a
dummy value, re-rendered, confirmed the dummy value flowed through to the
rendered `image:` line for exactly those three containers and nowhere
else, then reverted. See `task-G1-report.md` for the transcript.

`helm template t charts/bdp --set observability.enabled=false` render is
still byte-identical before/after — the disabled path was never touched.

## Log collector + platform ServiceMonitors (Task H1)

Two gaps found by the final whole-branch review: Loki (Task E1) had no log
source at all (20Gi PVC, nothing ever wrote to it), and no ServiceMonitor
existed anywhere in this chart for the 22 BDP platform services rendered by
`templates/services.yaml` (Task E2's 26 ServiceMonitors live only in
`bdp-helm-charts`, which this marketplace chart does not consume).

### Collector choice: Grafana Alloy, not Promtail

Promtail entered LTS-only maintenance in Feb 2025 with an announced 2026
EOL — the wrong engine to depend on for a platform meant to outlive that.
Alloy is Grafana's current, actively-maintained log/metrics/trace shipper
and is already the pinned engine used by grafana/loki 7.1.0's own upstream
guidance for new installs. Vendored the same way as Task E1's
kube-prometheus-stack + Loki: `helm pull grafana/alloy --version 1.11.0
--untar`, decompressed under `charts/bdp/charts/alloy/` (gitignored,
working-tree only — reproduce on the build host from this document), added
as a Chart.yaml dependency gated on the same `observability.enabled`
condition. Alloy's own nested `charts/crds` subchart (a single
`monitoring.grafana.com_podlogs.yaml` CRD) ships as a plain directory in the
packaged chart already, not a `.tgz` — no further decompression needed —
and is disabled below since nothing here uses the PodLogs CR.

### Discovery/shipping config (no hostPath)

`alloy.alloy.configMap.content` in `values.yaml` overrides the chart's
default (empty) config with:

```river
discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets
  rule { source_labels = ["__meta_kubernetes_namespace"]; target_label = "namespace" }
  rule { source_labels = ["__meta_kubernetes_pod_name"]; target_label = "pod" }
  rule { source_labels = ["__meta_kubernetes_pod_container_name"]; target_label = "container" }
  rule { source_labels = ["__meta_kubernetes_pod_node_name"]; target_label = "node" }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint { url = "http://bdp-observability-loki:3100/loki/api/v1/push" }
}
```

`loki.source.kubernetes` tails every pod's logs via the Kubernetes API
server's `pods/log` subresource instead of a hostPath `/var/log` mount (the
Promtail-style approach) — this chart ships to arbitrary clusters, including
managed/restricted ones, so avoiding a hostPath volume + its securityContext
implications was the deciding factor over the (lower-API-load) file-tailing
alternative. Push path verified against the vendored Loki chart's rendered
single-binary Service (`bdp-observability-loki`, port 3100 —
`loki.server.http_listen_port`, the Loki server's native HTTP API, not the
gateway/nginx Service) rather than assumed.

`controller.type` defaults to `daemonset` in this chart version — left at
default so every node's pods are covered. This chart's own default
`rbac.rules` + `rbac.clusterRules` (left at default, `rbac.create: true`)
already grant everything `discovery.kubernetes` + `loki.source.kubernetes`
need (`pods`, `pods/log`, `namespaces`, `nodes`, `nodes/pods`,
`nodes/metrics`) — no RBAC override was necessary.

### CPA image sourcing

Two containers, both patched to read `.Values.global.azure.images` directly
(same idiom as every other patch in this document):

**`charts/bdp/charts/alloy/templates/containers/_agent.yaml`** (container
`alloy`) — new image, mirrored `grafana/alloy:v1.18.0` →
`bdpmarketplace.azurecr.io/tools/alloy:v1.18.0`
(`sha256:491b0578c04983fd54fe99b587b6fab4404dc46d0dc16677bd6b00cc1140b308`,
confirmed identical to the upstream digest — single-manifest image, digest
survived the pull/tag/push round trip), new `global.azure.images.alloy` key:

```diff
- name: alloy
-  image: {{ .Values.global.image.registry | default .Values.image.registry }}/{{ .Values.image.repository }}{{ include "alloy.imageId" . }}
+  image: "{{ (index .Values.global.azure.images "alloy").registry }}/{{ (index .Values.global.azure.images "alloy").image }}@{{ (index .Values.global.azure.images "alloy").digest }}"
```

**`charts/bdp/charts/alloy/templates/containers/_watch.yaml`** (container
`config-reloader`) — deliberately reuses the existing `config-reloader` key
from the kube-prometheus-stack section above (identical upstream image,
`quay.io/prometheus-operator/prometheus-config-reloader`; its
`--watched-dir`/`--reload-url` flags are generic, not Prometheus-specific).
Verified by temporarily overriding `global.azure.images.config-reloader.digest`
to a dummy value and confirming it flowed through to **both** the
kube-prometheus-stack `config-reloader` CLI arg and Alloy's `config-reloader`
container in one render — same tool, one manifest entry, not a coincidence:

```diff
- name: config-reloader
-  image: {{ .Values.global.image.registry | default .Values.configReloader.image.registry }}/{{ .Values.configReloader.image.repository }}{{ include "config-reloader.imageId" . }}
+  image: "{{ (index .Values.global.azure.images "config-reloader").registry }}/{{ (index .Values.global.azure.images "config-reloader").image }}@{{ (index .Values.global.azure.images "config-reloader").digest }}"
```

### Platform ServiceMonitors + selector match (`charts/bdp/templates/services.yaml`)

Every `.Values.services` entry's Deployment `containerPort` and Service
`port` are now named `http` (were unnamed) — required for a ServiceMonitor
to target them by name, and harmless with `observability.enabled: false`
since naming a port has no behavior of its own.

A second `{{- range $name, $svc := $root.Values.services }}` block, gated on
`observability.enabled`, emits one `ServiceMonitor` per service:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ $name }}
  labels:
    app.kubernetes.io/name: {{ $name }}
    app.kubernetes.io/part-of: bdp
    release: {{ $root.Release.Name }}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 30s
```

The `release: {{ $root.Release.Name }}` label is the fix for the second half
of the gap: the vendored kube-prometheus-stack's Prometheus CR defaults
`serviceMonitorSelector.matchLabels.release` to the Helm release name
(`prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: true`, the chart's
own default, left untouched) — matched the convention rather than widening
the CR's selector, so any other ServiceMonitor installed into the same
release (present or future) is picked up the same way. `/actuator/prometheus`
on the service's own port is correct because every service in
`.Values.services` depends on `bdp-common`, which carries
`micrometer-registry-prometheus` (Task E2) and does not override
`management.server.port` — metrics are served on the same port as the app.

### Verification

```
$ helm dependency list charts/bdp | grep alloy
alloy                 1.11.0   https://grafana.github.io/helm-charts   unpacked

$ helm template t charts/bdp --set observability.enabled=true | grep "kind: DaemonSet" -A2 | grep -A1 t-alloy
kind: DaemonSet
metadata:
  name: t-alloy

$ helm template t charts/bdp --set observability.enabled=true | grep "tools/alloy@"
image: "bdpmarketplace.azurecr.io/tools/alloy@sha256:491b0578c04983fd54fe99b587b6fab4404dc46d0dc16677bd6b00cc1140b308"

# 22 platform ServiceMonitors, one per .Values.services entry, all labeled release: t
# matching the Prometheus CR's serviceMonitorSelector.matchLabels.release: "t"

$ helm template t charts/bdp --set observability.enabled=true | grep -E "image: \"?[a-zA-Z0-9]" | grep -vc "bdpmarketplace.azurecr.io"
0

$ helm template t charts/bdp --set observability.enabled=false | grep -c "kind: DaemonSet\|kind: ServiceMonitor\|tools/alloy"
0
# disabled render diffs from the pre-H1 baseline ONLY in the http port names
# added to every service's Deployment/Service (no collector, no
# ServiceMonitors, no behavior change) — confirmed by diffing against a
# baseline render with both the tracked H1 changes AND the untracked vendored
# charts/bdp/charts/alloy/ directory removed (a plain git stash isn't enough:
# the vendored directory is gitignored, so Helm would otherwise render it
# unconditionally — Chart.yaml's condition: only applies when the dependency
# entry itself is present).

$ helm lint charts/bdp && helm lint charts/bdp --set observability.enabled=true
==> Linting charts/bdp
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed
(both runs)
```
