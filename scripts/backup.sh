#!/bin/bash
# Executa o backup de UM banco configurado em databases.yml.
# Uso: backup.sh <id>
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

DB_ID="${1:?uso: backup.sh <id>}"
require_db_exists "$DB_ID"

resolve_pg_env "$DB_ID" || exit 1

LOCAL_RETENTION_DAYS=$(db_get "$DB_ID" ".retention.local_days" "7")
FORMAT=$(db_get "$DB_ID" ".format" "custom")
DO_STRUCT_CHECK=$(db_get "$DB_ID" ".verify.structural_check" "true")
DO_CHECKSUM=$(db_get "$DB_ID" ".verify.checksum" "true")
DO_VERIFY_UPLOAD=$(db_get "$DB_ID" ".verify.verify_upload" "true")
DO_CHECKSUM_AFTER_UPLOAD=$(db_get "$DB_ID" ".verify.checksum_after_upload" "false")
DO_TEST_RESTORE=$(db_get "$DB_ID" ".verify.test_restore" "false")

notify "$DB_ID" start "iniciando backup"

case "$FORMAT" in
    custom) EXT="dump"; PGDUMP_FMT_FLAG="-Fc" ;;
    plain)  EXT="sql";  PGDUMP_FMT_FLAG="-Fp" ;;
    directory)
        fail_db "$DB_ID" "format: directory não é suportado ainda (pg_dump -Fd gera uma pasta com vários arquivos, e checksum/upload/verificação/retenção deste serviço assumem um dump = um arquivo só). Use custom ou plain."
        ;;
    *)
        fail_db "$DB_ID" "format '${FORMAT}' desconhecido (use custom ou plain)"
        ;;
esac

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
FILENAME="${DB_ID}_${TIMESTAMP}.${EXT}"
FILEPATH="${BACKUP_DIR}/${FILENAME}"

mkdir -p "$BACKUP_DIR"
log "$DB_ID" "iniciando dump de '${PG_DATABASE}' em ${PG_HOST}:${PG_PORT} -> ${FILEPATH}"

# -Fc: formato custom (binário, comprimido, portátil, permite restore seletivo/paralelo).
pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" \
    "$PGDUMP_FMT_FLAG" -Z 6 --no-owner --no-privileges -f "$FILEPATH" \
    || fail_db "$DB_ID" "pg_dump retornou erro"

if [ "$DO_STRUCT_CHECK" = "true" ] && [ "$FORMAT" != "plain" ]; then
    pg_restore --list "$FILEPATH" >/dev/null 2>&1 \
        || fail_db "$DB_ID" "dump gerado é inválido (pg_restore --list falhou)"
    log "$DB_ID" "checagem estrutural do dump OK"
fi

SHAFILE=""
if [ "$DO_CHECKSUM" = "true" ]; then
    SHAFILE="${FILEPATH}.sha256"
    sha256sum "$FILEPATH" | awk '{print $1}' > "$SHAFILE"
fi

SIZE=$(du -h "$FILEPATH" | cut -f1)
log "$DB_ID" "dump concluído (${SIZE}). Enviando para $(db_destinations_json "$DB_ID" | jq -rs '[.[].name] | join(", ")')"

FAILED_DEST=0
SUCCEEDED_DEST=0
DEST_COUNT=0
while IFS= read -r dest; do
    [ -z "$dest" ] && continue
    DEST_COUNT=$((DEST_COUNT + 1))
    TYPE=$(echo "$dest" | jq -r '.type')
    OK=0
    case "$TYPE" in
        s3|r2)
            upload_rclone "$DB_ID" "$dest" "$FILEPATH" "$SHAFILE" "$DO_VERIFY_UPLOAD" "$DO_CHECKSUM_AFTER_UPLOAD" && OK=1
            ;;
        oci_par)
            upload_oci_par "$DB_ID" "$dest" "$FILEPATH" "$SHAFILE" "$DO_VERIFY_UPLOAD" "$DO_CHECKSUM_AFTER_UPLOAD" && OK=1
            ;;
        local)
            upload_local "$DB_ID" "$dest" "$FILEPATH" "$SHAFILE" "$DO_VERIFY_UPLOAD" "$DO_CHECKSUM_AFTER_UPLOAD" && OK=1
            ;;
        *)
            log "$DB_ID" "AVISO: tipo de destino desconhecido '${TYPE}', ignorando"
            ;;
    esac
    if [ "$OK" = "1" ]; then
        SUCCEEDED_DEST=$((SUCCEEDED_DEST + 1))
    else
        FAILED_DEST=1
    fi
done < <(db_destinations_json "$DB_ID")

[ "$DEST_COUNT" -gt 0 ] || fail_db "$DB_ID" "nenhum destino configurado (destinations: vazio)"

if [ "$FAILED_DEST" = "1" ]; then
    if [ "$SUCCEEDED_DEST" -eq 0 ]; then
        fail_db "$DB_ID" "todos os destinos falharam no upload (backup local preservado em ${FILEPATH})"
    fi
    log "$DB_ID" "AVISO: ${SUCCEEDED_DEST}/${DEST_COUNT} destino(s) receberam o backup; os demais falharam"
    notify "$DB_ID" warning "backup parcialmente replicado (${SUCCEEDED_DEST}/${DEST_COUNT} destinos OK): ${FILENAME}. Reenvie com resend.sh $DB_ID ${FILENAME} para tentar de novo sem gerar um dump novo."
fi

# Retenção local: apaga dumps (e seus .sha256) mais antigos que X dias
find "$BACKUP_DIR" -maxdepth 1 -name "${DB_ID}_*" -mtime "+${LOCAL_RETENTION_DAYS}" -print -delete \
    | while read -r f; do log "$DB_ID" "removido backup local antigo: $f"; done

# Retenção remota (s3/r2/oci_par/local — cada tipo trata do seu jeito)
apply_remote_retention "$DB_ID" \
    || notify "$DB_ID" warning "algumas operações de retenção remota falharam para ${DB_ID} (veja os logs; não afeta o backup em si)"

if [ "$DO_TEST_RESTORE" = "true" ]; then
    run_test_restore "$DB_ID" "$FILEPATH" \
        || fail_db "$DB_ID" "verificação de restore de teste falhou"
fi

if [ "$FAILED_DEST" = "0" ]; then
    log "$DB_ID" "backup finalizado com sucesso: ${FILENAME}"
    notify "$DB_ID" success "backup concluído: ${FILENAME} (${SIZE})"
    exit 0
fi

# Chegou até aqui com FAILED_DEST=1: teve pelo menos um destino com sucesso
# (senão já teria saído via fail_db acima), então não é uma falha total —
# mas o exit code continua != 0 de propósito, pra quem monitora logs/cron
# perceber que esse backup não terminou 100% completo.
log "$DB_ID" "backup concluído com pendências: ${FILENAME} (destinos incompletos, veja aviso acima)"
exit 1
