{{/*
Ім'я Secret, що віддає n8n encryption key. Не плутати з CNPG-секретом БД,
який створюється самим оператором з ім'ям <cluster>-app.
*/}}
{{- define "n8n-env.secretName" -}}
n8n-app
{{- end }}

{{/*
Лейбли, що ставимо на всі ресурси цього релізу.
*/}}
{{- define "n8n-env.labels" -}}
app.kubernetes.io/name: n8n-env
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
