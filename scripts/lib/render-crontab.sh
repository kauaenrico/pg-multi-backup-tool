#!/bin/bash
# Gera, no stdout, um crontab (formato cron do usuário root) com uma linha por
# banco habilitado em `databases:`, usando o schedule do próprio banco ou o
# de `defaults.schedule` quando o banco não define o seu.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/common.sh"

echo "SHELL=/bin/bash"
echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# O cron só dá aos jobs um ambiente mínimo fixo (HOME/LOGNAME/PATH/SHELL/PWD) —
# NADA do .env chega aos jobs sozinho (confirmado testando: um job `env` sem
# isso não enxerga nenhuma variável do container). backup.sh/restore.sh
# resolvem senha, chaves e URLs de webhook/PAR via `${!nome_da_var}` em tempo
# de execução, então essas variáveis precisam estar escritas aqui, no próprio
# crontab, pra existirem quando o cron dispara o job sozinho — é assim que se
# resolve isso com cron, não tem outro mecanismo de propagação. Filtra só as
# poucas variáveis "de shell" que a gente já define explicitamente acima ou
# que não fazem sentido fora do processo do entrypoint.
env | grep -vE '^(PATH|HOME|SHELL|LOGNAME|PWD|OLDPWD|SHLVL|_|HOSTNAME)='

DEFAULT_SCHEDULE=$(yq e '.defaults.schedule // "0 3 * * *"' "$CONFIG_FILE")

yq e -o=json '.databases // []' "$CONFIG_FILE" | jq -c '.[]' | while IFS= read -r db; do
    id=$(echo "$db" | jq -r '.id')
    # `.enabled // true` seria um bug aqui: jq trata `false` como "vazio" no
    # operador `//`, revertendo um `enabled: false` explícito para true.
    enabled=$(echo "$db" | jq -r 'if .enabled == null then true else .enabled end')
    [ "$enabled" = "true" ] || { echo "[crontab] '${id}' desabilitado, pulando" >&2; continue; }

    schedule=$(echo "$db" | jq -r '.schedule // empty')
    [ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"

    echo "${schedule} /app/scripts/backup.sh ${id} >> /var/log/pg-backup/${id}.log 2>&1"
done
