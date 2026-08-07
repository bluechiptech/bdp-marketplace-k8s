{{/*
Docker image name for loki helm test
*/}}
{{- define "loki.helmTestImage" -}}
{{- /* Task G1: air-gapped, digest-pinned — sourced from global.azure.images */ -}}
{{- printf "%s/%s@%s" (index .Values.global.azure.images "loki-helm-test").registry (index .Values.global.azure.images "loki-helm-test").image (index .Values.global.azure.images "loki-helm-test").digest -}}
{{- end -}}


{{/*
test common labels
*/}}
{{- define "loki.helmTestLabels" -}}
{{ include "loki.labels" . }}
app.kubernetes.io/component: helm-test
{{- end }}
