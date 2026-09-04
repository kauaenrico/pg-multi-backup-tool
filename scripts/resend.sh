#!/bin/bash
# Reenvia um dump JÁ EXISTENTE localmente para os destinos configurados, sem
# rodar pg_dump de novo. Feito pra quando o dump deu certo mas o upload
# falhou (destino fora do ar, rede, etc.) — reprocessa na hora, sem esperar o
# próximo horário do cron.
#
# Uso:
#   resend.sh <id> latest [destino]         # pega o dump local mais recente desse banco
#   resend.sh <id> <arquivo> [destino]      # arquivo específico (nome ou caminho absoluto)
#
# Sem [destino], reenvia para TODOS os destinos configurados (inclusive os
# que já tinham funcionado da primeira vez — reenviar um destino que já está
# OK é inofensivo, só reescreve o mesmo conteúdo).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

DB_ID="${1:?uso: resend.sh <id> latest|<arquivo> [destino]}"
ARG="${2:?uso: resend.sh <id> latest|<arquivo> [destino]}"
DEST_NAME="${3:-}"
require_db_exists "$DB_ID"

if [ "$ARG" = "latest" ]; then
    FILENAME=$(find "$BACKUP_DIR" -maxdepth 1 -name "${DB_ID}_*" ! -name "*.sha256" -printf '%f\n' 2>/dev/null | sort | tail -n1)
    [ -n "$FILENAME" ] || { echo "[resend] ERRO: nenhum backup local encontrado para '${DB_ID}' em ${BACKUP_DIR}" >&2; exit 1; }
    FILEPATH="${BACKUP_DIR}/${FILENAME}"
else
    case "$ARG" in
        /*) FILEPATH="$ARG" ;;
        *)  FILEPATH="${BACKUP_DIR}/${ARG}" ;;
    esac
fi

[ -f "$FILEPATH" ] || { echo "[resend] ERRO: arquivo não encontrado: $FILEPATH" >&2; exit 1; }
FILENAME=$(basename "$FILEPATH")

SHAFILE=""
[ -f "${FILEPATH}.sha256" ] && SHAFILE="${FILEPATH}.sha256"

DO_VERIFY_UPLOAD=$(db_get "$DB_ID" ".verify.verify_upload" "true")
DO_CHECKSUM_AFTER_UPLOAD=$(db_get "$DB_ID" ".verify.checksum_after_upload" "false")

if [ -n "$DEST_NAME" ]; then
    log "$DB_ID" "reenviando '${FILENAME}' só para o destino '${DEST_NAME}' (reprocessamento manual)"
else
    log "$DB_ID" "reenviando '${FILENAME}' para todos os destinos configurados (reprocessamento manual)"
fi

FAILED=0
SUCCEEDED=0
TOTAL=0
while IFS= read -r dest; do
    [ -z "$dest" ] && continue
    NAME=$(echo "$dest" | jq -r '.name')
    [ -n "$DEST_NAME" ] && [ "$NAME" != "$DEST_NAME" ] && continue
    TOTAL=$((TOTAL + 1))
    TYPE=$(echo "$dest" | jq -r '.type')
    OK=0
    case "$TYPE" in
        s3|r2)   upload_rclone  "$DB_ID" "$dest" "$FILEPATH" "$SHAFILE" "$DO_VERIFY_UPLOAD" "$DO_CHECKSUM_AFTER_UPLOAD" && OK=1 ;;
        oci_par) upload_oci_par "$DB_ID" "$dest" "$FILEPATH" "$SHAFILE" "$DO_VERIFY_UPLOAD" "$DO_CHECKSUM_AFTER_UPLOAD" && OK=1 ;;
        local)   upload_local   "$DB_ID" "$dest" "$FILEPATH" "$SHAFILE" "$DO_VERIFY_UPLOAD" "$DO_CHECKSUM_AFTER_UPLOAD" && OK=1 ;;
        *) log "$DB_ID" "AVISO: tipo de destino desconhecido '${TYPE}', ignorando" ;;
    esac
    if [ "$OK" = "1" ]; then
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        FAILED=1
    fi
done < <(db_destinations_json "$DB_ID")

if [ -n "$DEST_NAME" ] && [ "$TOTAL" -eq 0 ]; then
    echo "[resend] ERRO: destino '${DEST_NAME}' não encontrado para '${DB_ID}'" >&2
    exit 1
fi

if [ "$FAILED" = "1" ] && [ "$SUCCEEDED" -eq 0 ]; then
    log "$DB_ID" "reenvio falhou em todos os destinos tentados (${TOTAL})"
    notify "$DB_ID" failure "reenvio manual falhou em todos os destinos tentados: ${FILENAME}"
    exit 1
fi

apply_remote_retention "$DB_ID" \
    || notify "$DB_ID" warning "algumas operações de retenção remota falharam para ${DB_ID} (veja os logs; não afeta o reenvio em si)"

if [ "$FAILED" = "1" ]; then
    log "$DB_ID" "reenvio parcialmente concluído (${SUCCEEDED}/${TOTAL} destinos OK)"
    notify "$DB_ID" warning "reenvio manual parcialmente concluído (${SUCCEEDED}/${TOTAL} destinos OK): ${FILENAME}"
    exit 1
fi

log "$DB_ID" "reenvio concluído com sucesso (${SUCCEEDED}/${TOTAL} destinos): ${FILENAME}"
notify "$DB_ID" success "reenvio manual concluído com sucesso: ${FILENAME}"
