{{/*
Shared helpers.

The Postgres and Keycloak helpers here exist so that facts stated in more than
one place cannot drift apart. Two cases in particular:

  * The database is addressed twice in two different languages — an Npgsql
    connection string for the API and Web, and a JDBC URL for Keycloak. Same
    server, same TLS posture, different spelling of every token.

  * Keycloak's path prefix appears as KC_HTTP_RELATIVE_PATH on the Keycloak pod
    AND inside the URL the API is told to call it on. Those are server-to-server
    calls that never pass through the ingress, so nothing adds the prefix for
    them. If they disagree, every token exchange 404s and nobody can sign in —
    while Keycloak's own health endpoint keeps reporting ready, because the
    management interface is pinned to "/" separately. That is #1217.

Anything a guard test needs to prove is derived from ONE source belongs here.
*/}}

{{/* ── Naming and labels ──────────────────────────────────────────── */}}

{{- define "tms.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tms.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "tms.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels for one component.

Deliberately NOT including chart or version: selectors are immutable on a
Deployment, so a chart upgrade that changed them would make every upgrade fail
with "field is immutable" and need a manual delete.

Usage: {{ include "tms.selectorLabels" (dict "component" "api") }}
*/}}
{{- define "tms.selectorLabels" -}}
app: tms-{{ .component }}
{{- end -}}

{{/*
Image reference. A digest wins over a tag when both are present, so the release
packaging can pin without having to blank the tag.
*/}}
{{- define "tms.image" -}}
{{- if .digest -}}
{{ .repository }}@{{ .digest }}
{{- else -}}
{{ .repository }}:{{ .tag }}
{{- end -}}
{{- end -}}

{{/* ── Keycloak path prefix — ONE definition, three consumers ─────── */}}

{{/*
Normalised to a leading slash and no trailing slash, or empty for root.

Consumed by:
  * KC_HTTP_RELATIVE_PATH        (deployment-keycloak.yaml)
  * KC_HOSTNAME                  (deployment-keycloak.yaml)
  * Keycloak__BaseUrl            (configmap-tms-config.yaml) ← the #1217 pair
  * Keycloak__PublicBaseUrl      (configmap-tms-config.yaml)
  * the /auth ingress path       (ingress.yaml)
*/}}
{{- define "tms.keycloak.path" -}}
{{- $p := .Values.keycloak.relativePath | default "/" | trimSuffix "/" -}}
{{- if and $p (not (hasPrefix "/" $p)) -}}{{- $p = printf "/%s" $p -}}{{- end -}}
{{- $p -}}
{{- end -}}

{{/* In-cluster URL for the API's server-to-server calls. */}}
{{- define "tms.keycloak.internalUrl" -}}
http://keycloak:8080{{ include "tms.keycloak.path" . }}
{{- end -}}

{{/* Browser-facing URL. */}}
{{- define "tms.keycloak.publicUrl" -}}
https://{{ .Values.hostname }}{{ include "tms.keycloak.path" . }}
{{- end -}}

{{/* Ingress path. "/" when Keycloak is served at the root. */}}
{{- define "tms.keycloak.ingressPath" -}}
{{- include "tms.keycloak.path" . | default "/" -}}
{{- end -}}

{{/* ── PostgreSQL ─────────────────────────────────────────────────── */}}

{{/*
libpq / JDBC spelling of sslMode — the value verbatim.

Kept as a helper rather than inlined so that the Npgsql mapping below has a
visible counterpart, and a guard can assert the pair covers the same four modes.
*/}}
{{- define "tms.pg.sslModeLibpq" -}}
{{- .Values.postgres.sslMode -}}
{{- end -}}

{{/*
Npgsql spelling of the SAME four modes. Different tokens for identical meanings;
this mapping is the only place the translation happens.
*/}}
{{- define "tms.pg.sslModeNpgsql" -}}
{{- $m := .Values.postgres.sslMode -}}
{{- if eq $m "disable" -}}Disable
{{- else if eq $m "require" -}}Require
{{- else if eq $m "verify-ca" -}}VerifyCA
{{- else if eq $m "verify-full" -}}VerifyFull
{{- else -}}
{{- fail (printf "\n\npostgres.sslMode must be one of disable, require, verify-ca, verify-full — got %q.\n" $m) -}}
{{- end -}}
{{- end -}}

{{/* True when a CA certificate volume should be mounted. */}}
{{- define "tms.pg.mountsCa" -}}
{{- if .Values.postgres.caSecretName -}}true{{- end -}}
{{- end -}}

{{- define "tms.pg.caPath" -}}/etc/postgres-tls/ca.crt{{- end -}}

{{/*
Npgsql connection string for the API and Web.

The password is NOT interpolated here. It is referenced as $(TMS_DB_PASSWORD),
an env var declared earlier in the same container, which Kubernetes expands at
container start. Three reasons:

  * The chart works against a Secret it has no permission to read.
  * The password never enters the Helm release object. Helm stores every
    rendered manifest — Secret contents included — in a Secret in the release
    namespace, and keeps it for every revision it retains.
  * One string serves both the shared-role and separate-role Keycloak setups.

Consequence, and it is documented in the README: the database password must
contain no ';' (Npgsql's keyword separator) and no '$(' .
*/}}
{{- define "tms.pg.npgsql" -}}
Host={{ .Values.postgres.host }};Port={{ .Values.postgres.port }};Database={{ .Values.postgres.database }};Username={{ .Values.postgres.username }};Password=$(TMS_DB_PASSWORD);Ssl Mode={{ include "tms.pg.sslModeNpgsql" . }}
{{- if include "tms.pg.mountsCa" . -}}
;Root Certificate={{ include "tms.pg.caPath" . }}
{{- end -}}
{{- end -}}

{{/*
JDBC URL for Keycloak. Same server, same TLS posture, different language.

Credentials go in KC_DB_USERNAME / KC_DB_PASSWORD rather than the URL, so no
password appears here either.
*/}}
{{- define "tms.pg.jdbc" -}}
jdbc:postgresql://{{ .Values.postgres.host }}:{{ .Values.postgres.port }}/{{ .Values.postgres.keycloakDatabase }}?sslmode={{ include "tms.pg.sslModeLibpq" . }}
{{- if include "tms.pg.mountsCa" . -}}
&sslrootcert={{ include "tms.pg.caPath" . }}
{{- else if .Values.postgres.trustSystemCaStore -}}
&sslrootcert=system
{{- end -}}
{{- end -}}

{{/* Which Secret and key hold the application database password. */}}
{{- define "tms.pg.secretName" -}}
{{- .Values.secrets.existingSecret -}}
{{- end -}}
{{- define "tms.pg.secretKey" -}}Postgres__Password{{- end -}}

{{/* Keycloak's database user — the app role unless overridden. */}}
{{- define "tms.pg.keycloakUsername" -}}
{{- .Values.postgres.keycloak.username | default .Values.postgres.username -}}
{{- end -}}
{{- define "tms.pg.keycloakSecretName" -}}
{{- .Values.postgres.keycloak.existingSecret | default .Values.secrets.existingSecret -}}
{{- end -}}
{{- define "tms.pg.keycloakSecretKey" -}}
{{- if .Values.postgres.keycloak.existingSecret -}}
{{- .Values.postgres.keycloak.existingSecretKey -}}
{{- else -}}
{{- include "tms.pg.secretKey" . -}}
{{- end -}}
{{- end -}}

{{/*
CA volume and mount.

Included by the API, Web AND Keycloak pods from this one definition, so they
cannot end up gated on different conditions. When no CA is configured nothing is
emitted at all — which is what lets this chart run against a cluster that has no
CloudNativePG and therefore none of the Secrets the k3s target assumes.
*/}}
{{- define "tms.pg.caVolume" -}}
{{- if include "tms.pg.mountsCa" . }}
- name: postgres-ca
  secret:
    secretName: {{ .Values.postgres.caSecretName }}
    defaultMode: 0444
    items:
      - key: {{ .Values.postgres.caSecretKey | default "ca.crt" }}
        path: ca.crt
{{- end }}
{{- end -}}

{{- define "tms.pg.caVolumeMount" -}}
{{- if include "tms.pg.mountsCa" . }}
- name: postgres-ca
  mountPath: /etc/postgres-tls
  readOnly: true
{{- end }}
{{- end -}}

{{/* ── Request body size ──────────────────────────────────────────── */}}

{{/*
160 MB, in bytes.

Kestrel's limit and the ingress controller's body-size cap must agree, and the
ingress must never be the LOWER of the two: a manifest CSV and its companion
archive travel in a single multipart body, so a smaller proxy limit truncates
imports rather than rejecting them cleanly.

Both are rendered from this one number — Kestrel takes the bytes, the ingress
annotation takes the same value expressed in mebibytes — so they cannot be
changed apart.

The floor is Import:MaxFileSizeBytes + Import:MaxArchiveBytes. Do not lower it.
*/}}
{{- define "tms.maxRequestBodyBytes" -}}167772160{{- end -}}

{{- define "tms.maxRequestBodyMebibytes" -}}
{{- div (int64 (include "tms.maxRequestBodyBytes" .)) 1048576 -}}m
{{- end -}}

{{/* ── Redis ──────────────────────────────────────────────────────── */}}

{{/*
SignalR backplane connection string.

Rendered whenever Redis is enabled. The k3s target creates the password but
never this key, so its API silently runs an in-memory backplane on every
install — see TMS #1759.
*/}}
{{- define "tms.redis.connectionString" -}}
redis:6379,password=$(TMS_REDIS_PASSWORD)
{{- end -}}
