#!/bin/bash
# Gera, no stdout, um crontab (formato cron do usuário root) com uma linha por
# banco habilitado em `databases:`, usando o schedule do próprio banco (sem
# `defaults:` — cada banco é 100% independente; sem `schedule:`, cai no
# literal abaixo, que é só um valor padrão do script, não config compartilhada).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/common.sh"

echo "SHELL=/bin/bash"
echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
echo "TZ=${TZ:-America/Sao_Paulo}"
echo "CONFIG_FILE=${CONFIG_FILE}"
echo "BACKUP_DIR=${BACKUP_DIR}"

yq e -o=json '.databases // []' "$CONFIG_FILE" | jq -c '.[]' | while IFS= read -r db; do
    id=$(echo "$db" | jq -r '.id')
    # `.enabled // true` seria um bug aqui: jq trata `false` como "vazio" no
    # operador `//`, revertendo um `enabled: false` explícito para true.
    enabled=$(echo "$db" | jq -r 'if .enabled == null then true else .enabled end')
    [ "$enabled" = "true" ] || { echo "[crontab] '${id}' desabilitado, pulando" >&2; continue; }

    schedule=$(echo "$db" | jq -r '.schedule // empty')
    [ -n "$schedule" ] || schedule="0 3 * * *"

    echo "${schedule} /app/scripts/backup.sh ${id} >> /var/log/pg-backup/${id}.log 2>&1"
done
