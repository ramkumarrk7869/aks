{{- define "nginx-site.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nginx-site.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "nginx-site.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nginx-site.labels" -}}
app.kubernetes.io/name: {{ include "nginx-site.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
