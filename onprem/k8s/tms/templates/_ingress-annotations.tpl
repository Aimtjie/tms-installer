{{/*
Ingress annotations.

TMS needs four behaviours from whatever routes traffic to it. They are
functional requirements, not tuning:

  1. Long-lived connections must survive.  SignalR carries notifications and the
     Blazor Server circuit carries the whole first page render. A 60-second read
     timeout — the common default — closes both mid-session, which presents to
     users as the app randomly reloading.

  2. Request bodies up to 160 MB.  A ticket import sends a manifest CSV and its
     companion archive in ONE multipart body. A lower cap truncates the upload
     rather than rejecting it, so the import fails with a parse error that says
     nothing about size.

  3. Cookie session affinity on /hubs and /_blazor, and ONLY there.  See
     ingress.yaml for why.

  4. WebSocket upgrade.  ingress-nginx does this without configuration; some
     controllers do not.

`controller: nginx` renders the ingress-nginx spelling of all of this.
`controller: none` renders nothing and leaves it to you — in which case work
from the list above, not from the annotations below, because the annotation
names are ingress-nginx's and the requirements are TMS's.

Anything in .Values.ingressAnnotations / .Values.ingressStickyAnnotations is
merged over the preset, so any single value can be overridden without
abandoning the rest.
*/}}

{{- define "tms.ingress.baseAnnotations" -}}
{{- $preset := dict -}}
{{- if eq .Values.ingress.controller "nginx" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/proxy-read-timeout" "3600" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/proxy-send-timeout" "3600" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/proxy-body-size" (include "tms.maxRequestBodyMebibytes" .) -}}
{{- end -}}
{{- $merged := merge (deepCopy .Values.ingressAnnotations) $preset -}}
{{- if $merged }}
{{- toYaml $merged }}
{{- end }}
{{- end -}}

{{- define "tms.ingress.stickyAnnotations" -}}
{{- $preset := dict -}}
{{- if eq .Values.ingress.controller "nginx" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/proxy-read-timeout" "3600" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/proxy-send-timeout" "3600" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/proxy-body-size" (include "tms.maxRequestBodyMebibytes" .) -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/affinity" "cookie" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/affinity-mode" "persistent" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/session-cookie-name" "tms-affinity" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/session-cookie-path" "/" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/session-cookie-samesite" "Lax" -}}
{{- $_ := set $preset "nginx.ingress.kubernetes.io/session-cookie-max-age" "86400" -}}
{{- end -}}
{{- $merged := merge (deepCopy .Values.ingressStickyAnnotations) $preset -}}
{{- if $merged }}
{{- toYaml $merged }}
{{- end }}
{{- end -}}
