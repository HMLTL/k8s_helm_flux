# Тонка обгортка над офіційним n8n-образом. Сенс: мати власний тег у GHCR, щоб
# Flux Image Automation мав за чим стежити. Якщо потрібно — додавайте сюди
# custom nodes, npm-залежності, локалізації тощо.
ARG N8N_VERSION=1.71.3
FROM n8nio/n8n:${N8N_VERSION}

# Метадані OCI (CI підставляє реальні значення).
ARG GIT_SHA=dev
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.source="https://github.com/mykolap/k8s_helm_flux" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.title="n8n (k8s_helm_flux)" \
      org.opencontainers.image.description="n8n image для GitOps-демо (Flux + CNPG)"

# Місце для custom nodes:
# USER root
# RUN npm install -g n8n-nodes-mycustom
# USER node
