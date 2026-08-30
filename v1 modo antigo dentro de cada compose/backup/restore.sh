#!/bin/bash
set -uo pipefail

: "${PROJECT_NAME:?defina PROJECT_NAME no .env}"
: "${PGHOST:?defina PGHOST no .env}"
: "${PGPORT:=5432}"
: "${PGUSER:?defina PGUSER no .env}"
: "${PGPASSWORD:?defina PGPASSWORD no .env}"
: "${PGDATABASE:?defina PGDATABASE no .env}"

BACKUP_DIR="/backups"
R2_BUCKET="${R2_BUCKET:-}"
REMOTE_DIR="r2:${R2_BUCKET}/${PROJECT_NAME}/"

export PGPASSWORD

log() { echo "[restore] $(date -Iseconds) $*"; }
fail() { log "ERRO: $*"; exit 1; }

MODE="${1:-}"
FILEPATH=""

case "$MODE" in
    local)
        [ -n "${2:-}" ] || fail "informe o caminho do arquivo: ./restore.sh local <arquivo.dump>"
        FILEPATH="$2"
        [ -f "$FILEPATH" ] || fail "arquivo não encontrado: $FILEPATH"
        ;;
    latest)
        : "${R2_BUCKET:?defina R2_BUCKET no .env}"
        LATEST=$(rclone lsf "$REMOTE_DIR" --s3-no-check-bucket | sort | tail -n1)
        [ -n "$LATEST" ] || fail "nenhum backup encontrado em ${REMOTE_DIR}"
        FILEPATH="${BACKUP_DIR}/${LATEST}"
        log "baixando backup mais recente: ${LATEST}"
        rclone copy "${REMOTE_DIR}${LATEST}" "$BACKUP_DIR" --s3-no-check-bucket || fail "download falhou"
        ;;
    remote)
        : "${R2_BUCKET:?defina R2_BUCKET no .env}"
        [ -n "${2:-}" ] || fail "informe o nome do arquivo: ./restore.sh remote <arquivo.dump>"
        FILEPATH="${BACKUP_DIR}/$2"
        log "baixando ${2} do R2"
        rclone copy "${REMOTE_DIR}${2}" "$BACKUP_DIR" --s3-no-check-bucket || fail "download falhou"
        ;;
    *)
        fail "uso: ./restore.sh {local <arquivo>|latest|remote <arquivo>}"
        ;;
esac

log "restaurando '${FILEPATH}' em ${PGHOST}:${PGPORT}/${PGDATABASE} (usuário ${PGUSER})"
log "ATENÇÃO: isso vai recriar objetos existentes no banco de destino."
read -r -p "Confirma restauração em '${PGDATABASE}'? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { log "cancelado pelo usuário"; exit 0; }

# --clean --if-exists: apaga objetos antes de recriar (restore idempotente)
# -j 4: restaura em paralelo (4 jobs) — ajuste conforme CPU disponível
pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    --clean --if-exists --no-owner --no-privileges -j 4 "$FILEPATH" \
    || fail "pg_restore terminou com erros (alguns avisos sobre objetos inexistentes são normais com --clean --if-exists)"

log "restauração concluída com sucesso"
