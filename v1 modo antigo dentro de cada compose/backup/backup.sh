#!/bin/bash
set -uo pipefail

: "${PROJECT_NAME:?defina PROJECT_NAME no .env}"
: "${PGHOST:?defina PGHOST no .env}"
: "${PGPORT:=5432}"
: "${PGUSER:?defina PGUSER no .env}"
: "${PGPASSWORD:?defina PGPASSWORD no .env}"
: "${PGDATABASE:?defina PGDATABASE no .env}"
: "${LOCAL_RETENTION_DAYS:=7}"
: "${REMOTE_RETENTION_DAYS:=30}"
: "${R2_BUCKET:?defina R2_BUCKET no .env}"

BACKUP_DIR="/backups"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
FILENAME="${PROJECT_NAME}_${TIMESTAMP}.dump"
FILEPATH="${BACKUP_DIR}/${FILENAME}"
REMOTE_PATH="r2:${R2_BUCKET}/${PROJECT_NAME}/"

export PGPASSWORD

log() { echo "[backup] $(date -Iseconds) $*"; }

fail() {
    log "ERRO: $*"
    if [ -n "${WEBHOOK_URL:-}" ]; then
        curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
            -d "{\"text\":\"[${PROJECT_NAME}] backup FALHOU: $*\"}" \
            "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
    exit 1
}

mkdir -p "$BACKUP_DIR"

log "iniciando dump de '${PGDATABASE}' em ${PGHOST}:${PGPORT} -> ${FILEPATH}"

# -Fc: formato custom (binário, comprimido, portátil entre SOs/arquiteturas,
# permite restore seletivo e paralelo com pg_restore).
pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    -Fc -Z 6 --no-owner --no-privileges -f "$FILEPATH" \
    || fail "pg_dump retornou erro"

SIZE=$(du -h "$FILEPATH" | cut -f1)
log "dump concluído (${SIZE}). Enviando para ${REMOTE_PATH}"

rclone copy "$FILEPATH" "$REMOTE_PATH" --s3-no-check-bucket \
    || fail "envio ao R2 falhou (backup local preservado em ${FILEPATH})"

log "envio ao R2 concluído"

# Retenção local: apaga dumps locais mais antigos que X dias
find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.dump" -mtime "+${LOCAL_RETENTION_DAYS}" -print -delete \
    | while read -r f; do log "removido backup local antigo: $f"; done

# Retenção remota: apaga backups no R2 mais antigos que Y dias
rclone delete "$REMOTE_PATH" --min-age "${REMOTE_RETENTION_DAYS}d" --s3-no-check-bucket \
    || log "aviso: falha ao aplicar retenção remota (não é fatal)"

log "backup finalizado com sucesso: ${FILENAME}"
