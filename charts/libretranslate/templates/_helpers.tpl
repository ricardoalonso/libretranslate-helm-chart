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
