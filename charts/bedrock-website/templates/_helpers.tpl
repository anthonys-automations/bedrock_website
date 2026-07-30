{{/*
Resource name for the release. Everything is named after the release so an
existing site keeps the names its Secret, PVC subPath and immutable label
selector already use.
*/}}
{{- define "bedrock-website.fullname" -}}
{{- if not (regexMatch "^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$" .Release.Name) -}}
{{- fail "releaseName must be a DNS label such as anthonysautomations-prod (lowercase letters, digits and dashes; no dots)" -}}
{{- end -}}
{{- .Release.Name -}}
{{- end -}}

{{/*
Selector labels. `app` is what the pre-Helm Deployments selected on and a
Deployment's selector cannot be changed afterwards, so it stays.
*/}}
{{- define "bedrock-website.selectorLabels" -}}
app: {{ include "bedrock-website.fullname" . }}
{{- end -}}

{{- define "bedrock-website.labels" -}}
{{ include "bedrock-website.selectorLabels" . }}
app.kubernetes.io/name: bedrock-website
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "bedrock-website.hostname" -}}
{{- $hostname := required "hostname is required (see charts/bedrock-website/examples/<release-name>)" .Values.hostname -}}
{{- if not (regexMatch "^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:[.][a-z0-9](?:[-a-z0-9]*[a-z0-9])?)+$" $hostname) -}}
{{- fail "hostname must be a dotted DNS name such as www.anthonysautomations.com" -}}
{{- end -}}
{{- $hostname -}}
{{- end -}}

{{- define "bedrock-website.dbPasswordSecret" -}}
{{- required "dbPasswordSecret is required (see charts/bedrock-website/examples/<release-name>)" .Values.dbPasswordSecret -}}
{{- end -}}
