# Usamos a imagem "latest" do Postgres apenas como CLIENTE (pg_dump/pg_restore/psql).
# O protocolo de dump/restore do Postgres é retrocompatível: um pg_dump/pg_restore
# mais novo sabe conversar com servidores mais antigos, então um único container
# consegue fazer backup de bancos em várias versões diferentes do Postgres.
FROM postgres:latest

ARG YQ_VERSION=v4.44.3
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        bsdextrautils \
        ca-certificates \
        cron \
        curl \
        jq \
        msmtp \
        tzdata \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# rclone: envia/baixa/lista/deleta backups em qualquer remote S3-compatível (S3, R2, etc.)
RUN curl -fsSL https://rclone.org/install.sh | bash

# yq (mikefarah, binário Go estático): consulta o databases.yml a partir dos scripts bash.
RUN curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH:-amd64}" \
    && chmod +x /usr/local/bin/yq

ENV TZ=America/Sao_Paulo \
    CONFIG_FILE=/app/config/databases.yml \
    BACKUP_DIR=/backups

WORKDIR /app

COPY scripts/ /app/scripts/
COPY config/databases.example.yml /app/config/databases.example.yml

RUN chmod +x /app/scripts/*.sh /app/scripts/lib/*.sh \
    && mkdir -p /backups /var/log/pg-backup

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD []
