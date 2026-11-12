{{- define "bdp.image" -}}
{{- $img := index .root.Values.global.azure.images .name -}}
{{ $img.registry }}/{{ $img.image }}@{{ $img.digest }}
{{- end -}}

{{- define "bdp.keycloakInternalUrl" -}}
{{- /* Keycloak serves under httpRelativePath ("/auth" in IP mode) for ALL
       clients, in-cluster ones included -- the internal URL must carry the
       same prefix or the seed job and every service's issuer URI 404.
       Namespace-qualified, because this URL also reaches TOOL pods in other
       namespaces (NiFi's OIDC discovery), and because service-manager treats
       a ".svc" host as proof the address is pod-reachable cluster DNS.

       SUBCHART-SAFE on purpose: Grafana's grafana.ini entries in values.yaml
       reference this helper, and the grafana subchart tpl-renders them in its
       OWN scope, where .Values.keycloak does not exist -- a bare
       .Values.keycloak.httpRelativePath nil-pointered every render of HEAD
       (helm template/install both die). When the key is absent, fall back to
       inferring the prefix from IP mode, which is the exact invariant the
       fail-fast in ingress.yaml enforces on the parent values anyway. */ -}}
{{- $relPath := "" -}}
{{- if and .Values.keycloak .Values.keycloak.httpRelativePath -}}
{{- $relPath = .Values.keycloak.httpRelativePath | trimSuffix "/" -}}
{{- else if include "bdp.isIpMode" . -}}
{{- $relPath = "/auth" -}}
{{- end -}}
http://{{ .Release.Name }}-keycloak.{{ .Release.Namespace }}.svc.cluster.local:80{{ $relPath }}
{{- end -}}

{{/*
IP MODE. True when global.externalDomain is a bare IPv4 literal rather than a
hostname, which is the whole opt-in -- there is no separate switch to keep in
sync. Nothing else can match this regex: a real domain cannot have an all-numeric
TLD, so no hostname is ever mistaken for an address.

It exists because an IP has no subdomains. The domain layout puts Keycloak on
keycloak.<domain>, and "keycloak.10.0.4.83" is not a name anything can resolve,
so IP mode moves Keycloak to a PATH on the single address instead (/auth) and
collapses the Ingress to one host-less rule.
*/}}
{{- define "bdp.isIpMode" -}}
{{- if regexMatch "^([0-9]{1,3}\\.){3}[0-9]{1,3}$" .Values.global.externalDomain -}}true{{- end -}}
{{- end -}}

{{/*
The scheme every externally-facing URL is built from. Follows whether a
certificate exists, exactly as the Keycloak KC_HOSTNAME_URL in values.yaml
already did -- the rest of the chart used to hardcode https, which silently
broke every plain-HTTP install (the UI pod would call an https URL that the
ingress was not serving).
*/}}
{{- define "bdp.scheme" -}}
http{{ if .Values.global.tlsSecretName }}s{{ end }}
{{- end -}}

{{- define "bdp.platformBaseUrl" -}}
{{ include "bdp.scheme" . }}://{{ .Values.global.externalDomain }}
{{- end -}}

{{/*
Where browsers reach Keycloak. Domain mode: its own subdomain. IP mode: the
/auth path on the single address, which requires KC_HTTP_RELATIVE_PATH=/auth on
the Keycloak side (set in values.yaml) so Keycloak advertises the same prefix it
is served on -- otherwise its discovery document hands out URLs that 404.
*/}}
{{- define "bdp.keycloakBaseUrl" -}}
{{- if include "bdp.isIpMode" . -}}
{{ include "bdp.platformBaseUrl" . }}/auth
{{- else -}}
{{ include "bdp.scheme" . }}://keycloak.{{ .Values.global.externalDomain }}
{{- end -}}
{{- end -}}

{{- define "bdp.keycloakExternalIssuer" -}}
{{ include "bdp.keycloakBaseUrl" . }}/realms/bdp
{{- end -}}

{{- define "bdp.postgresHost" -}}
bdp-postgres
{{- end -}}

{{/* Environment shared by every Spring Boot service */}}
{{- define "bdp.commonEnv" -}}
- name: SPRING_PROFILES_ACTIVE
  value: prod
{{- /* Non-root uid 10001 has no writable home in pre---create-home images and
       Java resolves user.home from /etc/passwd (NOT $HOME) — force it writable
       for services that persist under it (cluster-registry FileSecretBackend) */}}
- name: HOME
  value: /tmp
- name: JAVA_OPTS
  value: "-Xms256m -Xmx768m -Duser.home=/tmp"
- name: BDP_EXTERNAL_HOST
  value: {{ .Values.global.externalDomain | quote }}
- name: BDP_KEYCLOAK_ISSUER_URI
  value: {{ include "bdp.keycloakInternalUrl" . }}/realms/bdp
- name: BDP_KEYCLOAK_EXTERNAL_ISSUER
  value: {{ include "bdp.keycloakExternalIssuer" . }}
- name: BDP_CORS_ALLOWED_ORIGINS
  value: {{ include "bdp.platformBaseUrl" . }}
{{- /* IngressManager uses this to class per-tool UI ingresses (default traefik) */}}
- name: BDP_INGRESS_CLASS
  value: {{ .Values.global.ingressClassName | quote }}
{{- if .Values.global.airgapRegistry }}
- name: BDP_AIRGAP_REGISTRY
  value: {{ .Values.global.airgapRegistry | quote }}
{{- end }}
{{- if .Values.global.airgapRegistryUsername }}
- name: BDP_AIRGAP_REGISTRY_USERNAME
  valueFrom:
    secretKeyRef: { name: bdp-airgap-registry, key: username }
- name: BDP_AIRGAP_REGISTRY_PASSWORD
  valueFrom:
    secretKeyRef: { name: bdp-airgap-registry, key: password }
{{- end }}
- name: BDP_SECRET_MASTER_KEY
  valueFrom:
    secretKeyRef: { name: bdp-platform-secrets, key: master-key }
{{- end -}}
