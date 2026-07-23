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
- name: BDP_EXTERNAL_HOST
  value: {{ .Values.global.externalDomain | quote }}
- name: BDP_KEYCLOAK_ISSUER_URI
  value: {{ include "bdp.keycloakInternalUrl" . }}/realms/bdp
- name: BDP_KEYCLOAK_EXTERNAL_ISSUER
  value: {{ include "bdp.keycloakExternalIssuer" . }}
- name: BDP_CORS_ALLOWED_ORIGINS
  value: https://{{ .Values.global.externalDomain }}
- name: BDP_SECRET_MASTER_KEY
  valueFrom:
    secretKeyRef: { name: bdp-platform-secrets, key: master-key }
{{- end -}}
