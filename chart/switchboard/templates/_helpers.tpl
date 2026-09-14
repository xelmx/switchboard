{{/*
Names and labels, computed once and reused, so every object in the release
agrees on them. `helm template` shows the result.
*/}}

{{- define "switchboard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* release-name-chart-name, unless they already match; 63 chars is the k8s limit */}}
{{- define "switchboard.fullname" -}}
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

{{- define "switchboard.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Two label sets, and the difference matters:

  selectorLabels — what the Deployment and Service match on. Immutable in a
                   Deployment's selector, so it must never contain a version.
  labels         — selectorLabels plus chart/version/managed-by, for humans
                   and for `kubectl get -l`.

Put the chart version in the selector and the first `helm upgrade` after a
version bump is rejected: the selector field cannot be changed in place.
*/}}
{{- define "switchboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "switchboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "switchboard.labels" -}}
helm.sh/chart: {{ include "switchboard.chart" . }}
{{ include "switchboard.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
