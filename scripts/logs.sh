#!/bin/bash
# Consulta os logs persistidos de um banco — cron e execução manual (backup.sh,
# resend.sh, restore.sh, verify.sh) escrevem tudo no mesmo arquivo
# (LOG_DIR/<id>.log), rotacionado diariamente pelo logrotate (mantém 14 dias,
# comprimidos: <id>.log.1, <id>.log.2.gz, ..., <id>.log.14.gz).
#
# Uso:
#   logs.sh                        lista os arquivos de log existentes
#   logs.sh <id>                    últimas 50 linhas do log atual
#   logs.sh <id> --tail N            últimas N linhas
#   logs.sh <id> --follow             acompanha em tempo real (tail -f)
#   logs.sh <id> --grep <termo>        procura o termo em TODOS os arquivos desse banco (atual + rotacionados, inclusive .gz)
#   logs.sh <id> --all                  concatena tudo, do mais antigo pro mais novo
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

# precisa bater com o "rotate 14" de render-logrotate.sh
MAX_ROTATIONS=14

if [ $# -eq 0 ]; then
    echo "Arquivos de log em ${LOG_DIR}:"
    ls -la "$LOG_DIR" 2>/dev/null || echo "(nenhum ainda — ninguém rodou backup.sh/resend.sh/restore.sh/verify.sh ainda)"
    exit 0
fi

DB_ID="$1"; shift
LOGFILE="${LOG_DIR}/${DB_ID}.log"

MODE="tail"
ARG="50"
while [ $# -gt 0 ]; do
    case "$1" in
        --tail)   MODE="tail";   ARG="${2:?informe a quantidade de linhas}"; shift 2 ;;
        --follow) MODE="follow"; shift ;;
        --grep)   MODE="grep";   ARG="${2:?informe o termo a procurar}"; shift 2 ;;
        --all)    MODE="all";    shift ;;
        *) echo "opção desconhecida: $1" >&2; echo "uso: logs.sh <id> [--tail N | --follow | --grep <termo> | --all]" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    tail)
        [ -f "$LOGFILE" ] || { echo "[logs] sem log ainda para '${DB_ID}' (${LOGFILE})" >&2; exit 1; }
        tail -n "$ARG" "$LOGFILE"
        ;;
    follow)
        [ -f "$LOGFILE" ] || { echo "[logs] sem log ainda para '${DB_ID}' (${LOGFILE})" >&2; exit 1; }
        tail -f "$LOGFILE"
        ;;
    grep)
        files=()
        for n in $(seq "$MAX_ROTATIONS" -1 1); do
            [ -f "${LOGFILE}.${n}" ] && files+=("${LOGFILE}.${n}")
            [ -f "${LOGFILE}.${n}.gz" ] && files+=("${LOGFILE}.${n}.gz")
        done
        [ -f "$LOGFILE" ] && files+=("$LOGFILE")
        [ "${#files[@]}" -gt 0 ] || { echo "[logs] nenhum arquivo de log encontrado para '${DB_ID}'" >&2; exit 1; }
        zgrep -H -- "$ARG" "${files[@]}"
        ;;
    all)
        found=0
        for n in $(seq "$MAX_ROTATIONS" -1 1); do
            for f in "${LOGFILE}.${n}" "${LOGFILE}.${n}.gz"; do
                if [ -f "$f" ]; then
                    found=1
                    echo "=== $(basename "$f") ==="
                    case "$f" in *.gz) zcat "$f" ;; *) cat "$f" ;; esac
                fi
            done
        done
        if [ -f "$LOGFILE" ]; then
            found=1
            echo "=== $(basename "$LOGFILE") (atual) ==="
            cat "$LOGFILE"
        fi
        [ "$found" = "1" ] || { echo "[logs] nenhum arquivo de log encontrado para '${DB_ID}'" >&2; exit 1; }
        ;;
esac
