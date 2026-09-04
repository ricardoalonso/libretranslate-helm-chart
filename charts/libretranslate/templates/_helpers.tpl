{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "libretranslate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "libretranslate.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "libretranslate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "libretranslate.labels" -}}
helm.sh/chart: {{ include "libretranslate.chart" . }}
{{ include "libretranslate.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "libretranslate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "libretranslate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{/*
Whether to render an OpenShift compatible pod.

`openshift.enabled` is tri-state: left unset it is auto-detected from the
presence of the `security.openshift.io/v1` API, so the chart does the right
thing on OpenShift and on vanilla Kubernetes without being told. Set it to true
or false to force either mode - needed when rendering manifests offline with
`helm template`, which has no cluster to inspect.

Returns the string "true" or the empty string, both of which template `if`
treats the way you would expect.
*/}}
{{- define "libretranslate.isOpenShift" -}}
{{- $v := .Values.openshift.enabled -}}
{{- if kindIs "invalid" $v -}}
{{- if .Capabilities.APIVersions.Has "security.openshift.io/v1" }}true{{ end -}}
{{- else if eq (lower (toString $v)) "true" -}}
true
{{- end -}}
{{- end }}

{{/*
Home directory of the application user inside the container.

Set explicitly through the HOME env var because OpenShift runs the pod under an
arbitrary UID that has no /etc/passwd entry: without it Python resolves "~" to
"/" and argos-translate looks for the language models in the wrong place.
*/}}
{{- define "libretranslate.homeDir" -}}
{{- .Values.homeDir | default "/home/libretranslate" -}}
{{- end }}

{{/*
Directory argos-translate keeps the downloaded language models in.
*/}}
{{- define "libretranslate.modelsPath" -}}
{{- printf "%s/.local/share/argos-translate" (include "libretranslate.homeDir" .) -}}
{{- end }}

{{/*
Environment shared by the app container and the model pre-install init container.

argos-translate derives three directories from Path.home() and creates all of
them on import: the data dir, the config dir and the cache dir. Only the data
dir is a mount point that already exists, so on OpenShift the other two have to
be redirected somewhere the arbitrary UID can write - the image owns $HOME as
UID 1032 with mode 0755, so it cannot create them there. XDG_DATA_HOME is
deliberately left unset so the data dir keeps resolving to the mounted models
volume.
*/}}
{{- define "libretranslate.runtimeEnv" -}}
- name: HOME
  value: {{ include "libretranslate.homeDir" . | quote }}
{{- if include "libretranslate.isOpenShift" . }}
- name: XDG_CACHE_HOME
  value: {{ .Values.openshift.cacheDir | quote }}
- name: XDG_CONFIG_HOME
  value: {{ .Values.openshift.configDir | quote }}
{{- end }}
{{- end }}

{{/*
Labels for the volumeClaimTemplates.

`spec.volumeClaimTemplates` is immutable, so anything version-bearing in here
turns every chart release into a StatefulSet the API server refuses to patch:
`helm.sh/chart` carries the chart version and `app.kubernetes.io/version` the
app version, so bumping either one breaks `helm upgrade` with "updates to
statefulset spec for fields other than ... are forbidden". Only labels that
survive an upgrade unchanged belong on a PVC template.
*/}}
{{- define "libretranslate.pvcLabels" -}}
{{ include "libretranslate.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Port LibreTranslate binds inside the pod.

This is `appConfig.port`, exported as LT_PORT and used as the container port, so
the app, the probes and the `http` port the Service targets can never disagree.
`service.port` is a separate knob - the port the Service itself listens on -
which reaches the container through `targetPort: http` whatever this is set to.
*/}}
{{- define "libretranslate.appPort" -}}
{{- .Values.appConfig.port | default .Values.service.port | default 5000 -}}
{{- end }}

{{/*
Path of the /health endpoint the probes poll.

`appConfig.urlPrefix` mounts the whole WSGI app under the prefix, so /health
moves with it. Asking for the unprefixed path would not fail loudly - the app
answers it with a 301 to the prefix, which the kubelet counts as a healthy
response - so the prefix has to be part of the path.
*/}}
{{- define "libretranslate.healthPath" -}}
{{- $prefix := .Values.appConfig.urlPrefix | default "" | toString | trimSuffix "/" -}}
{{- if and $prefix (not (hasPrefix "/" $prefix)) -}}
{{- $prefix = printf "/%s" $prefix -}}
{{- end -}}
{{- printf "%s/health" $prefix -}}
{{- end }}

{{/*
Scheme the probes talk to the container with: with `appSettings.ssl` the app
serves TLS itself and a plain HTTP probe would never get an answer.
*/}}
{{- define "libretranslate.probeScheme" -}}
{{- if has (.Values.appSettings.ssl | default "" | toString | lower) (list "true" "1") -}}
HTTPS
{{- else -}}
HTTP
{{- end -}}
{{- end }}

{{/*
One probe block. Call with (dict "probe" .Values.<name>Probe "root" $).

The probe values hold timings only; the handler is filled in here so that it
tracks `appConfig.urlPrefix`, `appSettings.ssl` and the container port without
the user having to restate them. A probe that brings its own `httpGet`, `exec`,
`tcpSocket` or `grpc` block keeps it, and an empty probe renders nothing at all,
which is how a probe is turned off.
*/}}
{{- define "libretranslate.probe" -}}
{{- $root := .root -}}
{{- $probe := deepCopy (.probe | default dict) -}}
{{- if $probe -}}
{{- $custom := false -}}
{{- range $handler := list "httpGet" "exec" "tcpSocket" "grpc" -}}
{{- if hasKey $probe $handler -}}{{- $custom = true -}}{{- end -}}
{{- end -}}
{{- if not $custom -}}
{{- $_ := set $probe "httpGet" (dict
      "path" (include "libretranslate.healthPath" $root)
      "port" "http"
      "scheme" (include "libretranslate.probeScheme" $root)) -}}
{{- end -}}
{{- toYaml $probe -}}
{{- end -}}
{{- end }}

{{/*
Pod-level security context.

OpenShift's default `restricted-v2` SCC allocates the pod's UID, GID and fsGroup
from the namespace's `openshift.io/sa.scc.uid-range` and
`openshift.io/sa.scc.supplemental-groups` annotations, and rejects any pod that
pins its own. With `openshift.enabled` those keys are stripped so the SCC fills
them in; every other key is passed through as configured.
*/}}
{{- define "libretranslate.podSecurityContext" -}}
{{- $ctx := deepCopy (.Values.securityContext | default dict) -}}
{{- if include "libretranslate.isOpenShift" . -}}
{{- $ctx = omit $ctx "fsGroup" "runAsUser" "runAsGroup" -}}
{{- end -}}
{{- toYaml $ctx -}}
{{- end }}

{{/*
Container-level security context for the app container.
*/}}
{{- define "libretranslate.containerSecurityContext" -}}
{{- $ctx := deepCopy (.Values.podSecurityContext | default dict) -}}
{{- if include "libretranslate.isOpenShift" . -}}
{{- $ctx = omit $ctx "runAsUser" "runAsGroup" -}}
{{- end -}}
{{- toYaml $ctx -}}
{{- end }}

{{/*
Security context for the model pre-install init container.

Off OpenShift the init container chowns the freshly provisioned volumes, which
needs root. OpenShift forbids that and makes it unnecessary - the SCC-assigned
fsGroup already grants group write on every volume - so there the init container
runs with the same context as the app container.
*/}}
{{- define "libretranslate.initContainerSecurityContext" -}}
{{- if include "libretranslate.isOpenShift" . -}}
{{- include "libretranslate.containerSecurityContext" . -}}
{{- else -}}
{{- toYaml (.Values.initContainerSecurityContext | default dict) -}}
{{- end -}}
{{- end }}

{{/*
Which resource the service is exposed with: "ingress" or "route".

`ingress.kind` is auto by default, which picks an OpenShift Route on OpenShift
and a Kubernetes Ingress everywhere else. `route.openshift.io/v1` does not exist
on vanilla Kubernetes, so asking for a Route there is a hard error rather than a
manifest the API server would reject.
*/}}
{{- define "libretranslate.ingressKind" -}}
{{- $kind := .Values.ingress.kind | default "auto" | toString | lower -}}
{{- if eq $kind "auto" -}}
{{- if include "libretranslate.isOpenShift" . }}route{{ else }}ingress{{ end -}}
{{- else if eq $kind "ingress" -}}
ingress
{{- else if eq $kind "route" -}}
{{- if include "libretranslate.isOpenShift" . -}}
route
{{- else -}}
{{- fail "ingress.kind=route needs OpenShift/OKD: the route.openshift.io/v1 API does not exist on vanilla Kubernetes. Use ingress.kind=ingress, or set openshift.enabled=true if you are rendering Routes offline with `helm template`." -}}
{{- end -}}
{{- else -}}
{{- fail (printf "ingress.kind must be one of auto, ingress or route - got %q" $kind) -}}
{{- end -}}
{{- end }}

{{/*
The `ingress.tls` entry that serves a given host, as YAML - empty when the host
is served over plain HTTP. Call with (dict "host" <host> "root" $) and pipe the
result through `fromYaml`.

An entry without `hosts` serves every host, which keeps the common single
certificate case down to one block. First match wins.
*/}}
{{- define "libretranslate.tlsForHost" -}}
{{- $host := .host -}}
{{- $found := dict -}}
{{- range .root.Values.ingress.tls -}}
{{- if and (empty $found) (or (empty .hosts) (has $host .hosts)) -}}
{{- $found = . -}}
{{- end -}}
{{- end -}}
{{- if not (empty $found) -}}
{{- toYaml $found -}}
{{- end -}}
{{- end }}

{{/*
Name of the TLS secret an `ingress.tls` entry uses. Call with
(dict "entry" <entry> "root" $).
*/}}
{{- define "libretranslate.tlsSecretName" -}}
{{- $entry := .entry | default dict -}}
{{- $entry.secretName | default (printf "%s-tls" (include "libretranslate.fullname" .root)) -}}
{{- end }}

{{/*
Annotations for the Ingress or Route.

A Kubernetes Ingress has no portable field for "redirect HTTP to HTTPS", so with
`ingress.redirectHttpToHttps` the `ingress.redirectAnnotations` are merged in on
top of the configured ones - anything set in `ingress.annotations` wins, so the
defaults can be overridden per key. Routes express the redirect through
`insecureEdgeTerminationPolicy` instead and get the annotations unchanged.
*/}}
{{- define "libretranslate.ingressAnnotations" -}}
{{- $ann := deepCopy (.Values.ingress.annotations | default dict) -}}
{{- if and .Values.ingress.redirectHttpToHttps (not (empty .Values.ingress.tls)) (eq (include "libretranslate.ingressKind" .) "ingress") -}}
{{- $ann = merge $ann (deepCopy (.Values.ingress.redirectAnnotations | default dict)) -}}
{{- end -}}
{{- $out := list -}}
{{- range $k, $v := $ann -}}
{{- $out = append $out (printf "%s: %s" $k ($v | quote)) -}}
{{- end -}}
{{- join "\n" $out -}}
{{- end }}

{{/*
Validate the `ingress.tls` entries. Renders nothing; include it for the side
effect of failing early with a readable message instead of letting a half
configured certificate reach the API server.
*/}}
{{- define "libretranslate.validateIngressTLS" -}}
{{- range $i, $entry := .Values.ingress.tls -}}
{{- if and (or $entry.certificate $entry.privateKey) (not (and $entry.certificate $entry.privateKey)) -}}
{{- fail (printf "ingress.tls[%d] sets only one of certificate/privateKey - provide both to have the chart install the certificate, or neither to reference a secretName you created yourself" $i) -}}
{{- end -}}
{{- if and (empty $entry.certificate) (empty $entry.secretName) -}}
{{- if ne (include "libretranslate.ingressKind" $) "route" -}}
{{- fail (printf "ingress.tls[%d] needs either a secretName to reference or an inline certificate/privateKey pair" $i) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
