{{- define "bdp.image" -}}
{{ .root.Values.global.bdpImageRegistry }}/{{ .name }}:{{ .root.Values.global.bdpImageTag }}
{{- end -}}

{{- define "bdp.keycloakInternalUrl" -}}
http://{{ .Release.Name }}-keycloak:80
{{- end -}}

{{- define "bdp.keycloakExternalIssuer" -}}
https://keycloak.{{ .Values.global.externalDomain }}/realms/bdp
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
  value: https://{{ .Values.global.externalDomain }}
{{- /* IngressManager uses this to class per-tool UI ingresses (default traefik) */}}
- name: BDP_INGRESS_CLASS
  value: {{ .Values.global.ingressClassName | quote }}
{{- if .Values.global.airgapRegistry }}
- name: BDP_AIRGAP_REGISTRY
  value: {{ .Values.global.airgapRegistry | quote }}
{{- end }}
- name: BDP_SECRET_MASTER_KEY
  valueFrom:
    secretKeyRef: { name: bdp-platform-secrets, key: master-key }
{{- end -}}
