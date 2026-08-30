#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

[ -f "$CONFIG_FILE" ] || {
    echo "[entrypoint] ERRO: arquivo de config '${CONFIG_FILE}' não encontrado."
    echo "[entrypoint] Monte seu databases.yml em ${CONFIG_FILE} (veja config/databases.example.yml)."
    exit 1
}

mkdir -p "$BACKUP_DIR" /var/log/pg-backup

echo "[entrypoint] $(date -Iseconds) renderizando rclone.conf a partir de 'remotes:'"
"$DIR/lib/render-rclone-conf.sh"

echo "[entrypoint] $(date -Iseconds) gerando crontab a partir de 'databases:'"
"$DIR/lib/render-crontab.sh" > /tmp/crontab.generated
crontab /tmp/crontab.generated

echo "[entrypoint] bancos configurados:"
"$DIR/list.sh" || true

echo "[entrypoint] $(date -Iseconds) serviço de backup iniciado. Cron ativo:"
crontab -l

exec cron -f -l 2
