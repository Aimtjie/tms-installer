{{/*
Every install-time refusal, in one place.

Two layers cover bad input, and they are not redundant:

  * values.schema.json rejects what a machine can check — types, enums, the
    replica count. It runs first and its message is terse.

  * This file refuses the cases where the REASON is the point. A platform team
    that reads "must be const 1" concludes we were being conservative and works
    around it. A platform team that reads "a second replica adopts the import
    batch the first one is still writing" does not.

Included once from configmap-tms-config.yaml, which always renders.
*/}}
{{- define "tms.validate" -}}

{{- /* ── Required, with no sensible default ─────────────────────── */ -}}

{{- if not .Values.hostname }}
{{- fail "\n\nhostname is required.\n\nTMS is served from one hostname: the web app at /, the API at /api and sign-in\nat /auth. Set it to the DNS name that points at your ingress controller, with no\nscheme and no path:\n\n    --set hostname=tickets.example.internal\n" }}
{{- end }}

{{- if or (contains "://" .Values.hostname) (contains "/" .Values.hostname) }}
{{- fail (printf "\n\nhostname must be a bare host name, not a URL — got %q.\n\nThe chart builds the scheme and paths itself. Use:\n\n    hostname: tickets.example.internal\n" .Values.hostname) }}
{{- end }}

{{- if not .Values.tls.secretName }}
{{- fail "\n\ntls.secretName is required.\n\nCreate a kubernetes.io/tls Secret in this namespace holding a certificate that\ncovers `hostname`, with its full chain, then name it here:\n\n    kubectl -n <namespace> create secret tls tms-tls \\\n        --cert=fullchain.pem --key=privkey.pem\n\nThis chart does not require cert-manager and does not renew anything. Whoever\nissued the certificate owns renewing it.\n" }}
{{- end }}

{{- if not .Values.ingress.className }}
{{- fail "\n\ningress.className is required.\n\nThis chart assumes nothing about your ingress controller. List the classes your\ncluster offers with:\n\n    kubectl get ingressclass\n" }}
{{- end }}

{{- if not (has .Values.ingress.controller (list "nginx" "none")) }}
{{- fail (printf "\n\ningress.controller must be \"nginx\" or \"none\" — got %q.\n\n  nginx  render the ingress-nginx annotations TMS needs\n  none   render no annotations; you supply them via ingressAnnotations and\n         ingressStickyAnnotations. Read README section 4 first — the\n         requirements behind those annotations are functional, not cosmetic.\n" .Values.ingress.controller) }}
{{- end }}

{{- if and (not .Values.storage.className) (eq .Values.attachments.provider "local") }}
{{- fail "\n\nstorage.className is required.\n\nThe `local` attachment provider stores uploads on a PersistentVolumeClaim.\nReadWriteOnce is sufficient.\n\n    kubectl get storageclass\n\nNOTHING IN THIS CHART BACKS THIS VOLUME UP. Confirm your platform snapshots the\nclass you choose, or uploaded files exist in exactly one place.\n\nIf you have no class you would trust with the only copy of a customer's files,\nput the attachments in the database you already back up instead:\n\n    --set attachments.provider=postgres\n\nNo volume is created then, and this value is not read.\n" }}
{{- end }}

{{- if not .Values.postgres.host }}
{{- fail "\n\npostgres.host is required.\n\nThis chart never installs a database. It needs a PostgreSQL server you operate,\nwith two databases and a role that can log in to both — see README section 2 for\nthe SQL to hand your DBA.\n" }}
{{- end }}

{{- if not .Values.secrets.existingSecret }}
{{- fail "\n\nsecrets.existingSecret is required.\n\nThis chart generates no secret material. Create the Secret first — README\nsection 3 has the exact command.\n" }}
{{- end }}

{{- /* ── Database TLS: refuse the ambiguous combinations ─────────── */ -}}

{{- $verifying := hasPrefix "verify" .Values.postgres.sslMode }}

{{- if and $verifying (not .Values.postgres.caSecretName) (not .Values.postgres.trustSystemCaStore) }}
{{- fail (printf "\n\npostgres.sslMode is %q but there is nothing to verify the server against.\n\nEither point at a Secret holding your database server's CA certificate:\n\n    kubectl -n <namespace> create secret generic tms-db-ca \\\n        --from-file=ca.crt=/path/to/ca.crt\n    # then: --set postgres.caSecretName=tms-db-ca\n\nor, if your server presents a publicly trusted certificate:\n\n    --set postgres.trustSystemCaStore=true\n\nLeft as it is, the API, Web and Keycloak pods would all start and all fail to\nreach the database, which presents as three unrelated components crash-looping.\n" .Values.postgres.sslMode) }}
{{- end }}

{{- if and .Values.postgres.caSecretName (not $verifying) }}
{{- fail (printf "\n\npostgres.caSecretName is set but postgres.sslMode is %q, which does not verify\nthe server's certificate.\n\nThis combination is refused rather than ignored, because the two settings say\ndifferent things about what you intend and one of them is wrong:\n\n  * to authenticate the server, raise the mode:  --set postgres.sslMode=verify-full\n  * to encrypt only, drop the CA:                --set postgres.caSecretName=\"\"\n\nNote that since Npgsql 8, \"require\" means encrypt WITHOUT checking who you are\ntalking to — it is not a weaker spelling of verify.\n" .Values.postgres.sslMode) }}
{{- end }}

{{- /* ── Forwarded-header trust ──────────────────────────────────── */ -}}

{{- if and (empty .Values.network.trustedProxyCidrs) (not .Values.network.trustProxyRfc1918) }}
{{- fail "\n\nnetwork.trustedProxyCidrs is required.\n\nThis is the CIDR your ingress controller reaches the TMS pods from — usually the\ncluster pod network. Find it with:\n\n    kubectl get pod -n <ingress-namespace> -o wide\n\nand match the pod IPs against your cluster's pod CIDR. Then:\n\n    --set network.trustedProxyCidrs[0]=10.244.0.0/16\n\nIt decides which peers are allowed to set X-Forwarded-For and X-Forwarded-Proto.\nWithout it the API does not believe it is behind TLS: the first-run /setup wizard\nreturns 500 on antiforgery, secure cookies and HSTS stop behaving correctly, and\nper-IP rate limiting can be defeated with a spoofed header.\n\nIf you genuinely cannot determine it, fall back to trusting all private ranges:\n\n    --set network.trustProxyRfc1918=true\n\nThat is offered as a deliberate choice rather than a default because on an\ninternal deployment your own users are on RFC1918 addresses too, so it trusts\nthem to set their own forwarded headers.\n" }}
{{- end }}

{{- /* ── The API replica count ───────────────────────────────────── */ -}}

{{- if not (include "tms.keycloak.path" .) }}
{{- fail "\n\nkeycloak.relativePath cannot be \"/\".\n\nEverything is served from one hostname: the web app at /, the API at /api and\nsign-in under its own path. Keycloak and the web app cannot both own the root.\nThe ingress would route sign-in to the web app, which answers 404, and no\ncomponent would report anything wrong.\n\nUse a path with at least one segment:\n\n    --set keycloak.relativePath=/auth\n" }}
{{- end }}

{{- if ne (int .Values.api.replicas) 1 }}
{{- fail (printf "\n\napi.replicas must be 1 — got %d.\n\nThis is not conservatism. Five background services inside tms-api have no leader\nelection, so a second replica does not share the work, it repeats it:\n\n  * ReportSchedulerService advances a report's next-run time only AFTER it has\n    run, so the row stays due for the whole execution — YOUR CUSTOMERS RECEIVE\n    DUPLICATE SCHEDULED REPORTS.\n  * Both inbound mailbox pollers poll the same mailbox.\n  * SlaMonitoringService double-advances escalations.\n  * ImportProcessingService's recovery sweep selects every in-flight import\n    batch with no owner or heartbeat, so a STARTING REPLICA ADOPTS THE BATCH\n    ANOTHER REPLICA IS STILL WRITING. That one corrupts data.\n\nTracked upstream as TMS #1173 Track 2. When it lands this restriction is lifted\nin a chart release, and the value becomes an ordinary knob.\n\ntms-web scales freely — raise web.replicas instead. Its DataProtection keys live\nin the database and its Blazor circuits are pinned to a pod by the sticky\ningress this chart already configures.\n" (int .Values.api.replicas)) }}
{{- end }}

{{- /* ── Attachment provider ─────────────────────────────────────── */ -}}

{{- if not (has .Values.attachments.provider (list "local" "postgres")) }}
{{- fail (printf "\n\nattachments.provider must be \"local\" or \"postgres\" — got %q.\n\n  local      a PersistentVolumeClaim, mounted on the API pod at attachments.path\n  postgres   the bytes stored in your PostgreSQL server; no volume is created\n             and none is mounted\n\nThe value is checked here rather than passed through because these manifests\nhave to WIRE what it selects — the claim, the volume, the volumeMount and\nStorage__Provider all render from it. A provider this chart does not implement\nwould leave the API configured for storage that was never set up for it.\n" .Values.attachments.provider) }}
{{- end }}

{{- /* ── Realm ───────────────────────────────────────────────────── */ -}}

{{- if and .Values.keycloak.realm.existingConfigMap (not (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" .Values.keycloak.realm.existingConfigMap)) }}
{{- fail (printf "\n\nkeycloak.realm.existingConfigMap must be a valid resource name — got %q.\n" .Values.keycloak.realm.existingConfigMap) }}
{{- end }}

{{- end -}}
