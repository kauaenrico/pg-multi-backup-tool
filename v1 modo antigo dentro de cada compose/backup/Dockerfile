ARG PG_VERSION=16
FROM postgres:${PG_VERSION}-alpine

# rclone -> envia os backups para o Cloudflare R2 (compatível com S3)
# dcron  -> agendador (cron) dentro do container
# bash   -> os scripts usam bash
# tzdata -> cron rodar no horário certo (America/Sao_Paulo)
# curl   -> alerta via webhook se o backup falhar (opcional)
RUN apk add --no-cache bash tzdata rclone dcron curl

ENV TZ=America/Sao_Paulo

WORKDIR /backup

COPY backup.sh restore.sh entrypoint.sh /backup/
COPY crontab /etc/crontabs/root

RUN chmod +x /backup/backup.sh /backup/restore.sh /backup/entrypoint.sh

ENTRYPOINT ["/backup/entrypoint.sh"]
