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
