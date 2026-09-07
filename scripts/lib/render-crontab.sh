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
echo "LOG_DIR=${LOG_DIR}"
echo

# Rotaciona LOG_DIR/*.log uma vez por dia (config gerada por entrypoint.sh a
# partir de LOG_DIR — ver render-logrotate.sh). Log dessa própria rotação vai
# num arquivo à parte, pra não se misturar com o log de nenhum banco.
echo "0 0 * * * logrotate /etc/logrotate.d/pg-backup --state /var/lib/logrotate/pg-backup.state >> ${LOG_DIR}/logrotate.log 2>&1"

# backup.sh já redireciona a própria saída pra LOG_DIR/<id>.log sozinho (via
# start_logging em common.sh) — não precisa de `>> arquivo 2>&1` aqui.
yq e -o=json '.databases // []' "$CONFIG_FILE" | jq -c '.[]' | while IFS= read -r db; do
    id=$(echo "$db" | jq -r '.id')
    # `.enabled // true` seria um bug aqui: jq trata `false` como "vazio" no
    # operador `//`, revertendo um `enabled: false` explícito para true.
    enabled=$(echo "$db" | jq -r 'if .enabled == null then true else .enabled end')
    [ "$enabled" = "true" ] || { echo "[crontab] '${id}' desabilitado, pulando" >&2; continue; }

    schedule=$(echo "$db" | jq -r '.schedule // empty')
    [ -n "$schedule" ] || schedule="0 3 * * *"

    echo "${schedule} /app/scripts/backup.sh ${id}"
done
