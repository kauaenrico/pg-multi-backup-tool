#!/bin/bash
# Restaura o backup de UM banco configurado em databases.yml.
#
# Uso:
#   restore.sh <id> local  <caminho-do-arquivo.dump>
#   restore.sh <id> latest [nome-do-destino]
#   restore.sh <id> remote <nome-do-destino> <nome-do-arquivo>
#
# Sem [nome-do-destino], usa o primeiro destino configurado para o banco.
# Destinos do tipo oci_par não suportam "latest" (PAR não permite listar
# objetos do bucket) — use "remote <destino> <arquivo>" com o nome exato.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

DB_ID="${1:?uso: restore.sh <id> [local <arquivo> | latest [destino] | remote <destino> <arquivo>]}"
MODE="${2:-}"
require_db_exists "$DB_ID"
resolve_pg_env "$DB_ID" || exit 1

mkdir -p "$BACKUP_DIR"
FILEPATH=""

first_destination_name() {
    db_destinations_json "$DB_ID" | jq -rs 'first | .name // empty'
}

download_from_destination() {
    local dest_name="$1" fname="$2" dest type remote bucket prefix var url dest_path
    dest=$(find_destination "$DB_ID" "$dest_name")
    [ -n "$dest" ] || { echo "[restore] ERRO: destino '${dest_name}' não encontrado para '${DB_ID}'" >&2; exit 1; }
    type=$(echo "$dest" | jq -r '.type')
    case "$type" in
        s3|r2)
            remote=$(echo "$dest" | jq -r '.remote')
            bucket=$(echo "$dest" | jq -r '.bucket')
            prefix=$(echo "$dest" | jq -r '.prefix // ""')
            echo "[restore] baixando '${fname}' de '${dest_name}' (${remote}:${bucket}/${prefix})"
            rclone copy "${remote}:${bucket}/${prefix}${fname}" "$BACKUP_DIR" --s3-no-check-bucket \
                || { echo "[restore] ERRO: download falhou"; exit 1; }
            rclone copy "${remote}:${bucket}/${prefix}${fname}.sha256" "$BACKUP_DIR" --s3-no-check-bucket 2>/dev/null || true
            ;;
        oci_par)
            var=$(echo "$dest" | jq -r '.par_url_env')
            url="${!var:-}"
            [ -n "$url" ] || { echo "[restore] ERRO: variável '${var}' (PAR) não definida"; exit 1; }
            url="${url%/}"
            echo "[restore] baixando '${fname}' de '${dest_name}' (OCI PAR)"
            curl -fsS -o "${BACKUP_DIR}/${fname}" "${url}/${fname}" \
                || { echo "[restore] ERRO: download falhou (a PAR precisa permitir leitura)"; exit 1; }
            curl -fsS -o "${BACKUP_DIR}/${fname}.sha256" "${url}/${fname}.sha256" 2>/dev/null || true
            ;;
        local)
            dest_path=$(echo "$dest" | jq -r '.path')
            echo "[restore] copiando '${fname}' de '${dest_name}' (local: ${dest_path})"
            cp "${dest_path}/${fname}" "$BACKUP_DIR/" \
                || { echo "[restore] ERRO: cópia falhou (arquivo não encontrado em ${dest_path})"; exit 1; }
            cp "${dest_path}/${fname}.sha256" "$BACKUP_DIR/" 2>/dev/null || true
            ;;
        *)
            echo "[restore] ERRO: tipo de destino desconhecido '${type}'"; exit 1 ;;
    esac
}

case "$MODE" in
    local)
        FILEPATH="${3:?informe o caminho do arquivo: restore.sh $DB_ID local <arquivo.dump>}"
        [ -f "$FILEPATH" ] || { echo "[restore] ERRO: arquivo não encontrado: $FILEPATH" >&2; exit 1; }
        ;;
    latest)
        DEST_NAME="${3:-$(first_destination_name)}"
        [ -n "$DEST_NAME" ] || { echo "[restore] ERRO: nenhum destino configurado para '${DB_ID}'" >&2; exit 1; }
        DEST_JSON=$(find_destination "$DB_ID" "$DEST_NAME")
        DEST_TYPE=$(echo "$DEST_JSON" | jq -r '.type // empty')
        case "$DEST_TYPE" in
            s3|r2)
                REMOTE=$(echo "$DEST_JSON" | jq -r '.remote')
                BUCKET=$(echo "$DEST_JSON" | jq -r '.bucket')
                PREFIX=$(echo "$DEST_JSON" | jq -r '.prefix // ""')
                LATEST=$(rclone lsjson "${REMOTE}:${BUCKET}/${PREFIX}" --s3-no-check-bucket 2>/dev/null \
                    | jq -r --arg id "$DB_ID" '[.[] | select(.Name | startswith($id + "_")) | select(.Name | endswith(".sha256") | not)] | sort_by(.ModTime) | last | .Name // empty')
                ;;
            oci_par)
                # Só funciona em PARs de bucket criadas com "Enable Object
                # Listing" habilitado na OCI; sem isso o GET de listagem falha
                # e nada é retornado aqui.
                PAR_VAR=$(echo "$DEST_JSON" | jq -r '.par_url_env')
                PAR_URL="${!PAR_VAR:-}"
                [ -n "$PAR_URL" ] || { echo "[restore] ERRO: variável '${PAR_VAR}' (PAR) não definida" >&2; exit 1; }
                LATEST=$(oci_par_list_names "$PAR_URL" \
                    | grep -E "^${DB_ID}_" | grep -v '\.sha256$' | sort | tail -n1)
                if [ -z "$LATEST" ]; then
                    echo "[restore] ERRO: nenhum backup encontrado em '${DEST_NAME}' (a PAR precisa ter listagem habilitada; se não tiver, use: restore.sh $DB_ID remote $DEST_NAME <nome-do-arquivo>)" >&2
                    exit 1
                fi
                ;;
            local)
                LOCAL_DEST_PATH=$(echo "$DEST_JSON" | jq -r '.path')
                LATEST=$(find "$LOCAL_DEST_PATH" -maxdepth 1 -name "${DB_ID}_*" ! -name "*.sha256" -printf '%f\n' 2>/dev/null | sort | tail -n1)
                ;;
            *)
                echo "[restore] ERRO: tipo de destino desconhecido '${DEST_TYPE}'" >&2; exit 1 ;;
        esac
        [ -n "$LATEST" ] || { echo "[restore] ERRO: nenhum backup encontrado em '${DEST_NAME}'" >&2; exit 1; }
        download_from_destination "$DEST_NAME" "$LATEST"
        FILEPATH="${BACKUP_DIR}/${LATEST}"
        ;;
    remote)
        DEST_NAME="${3:?informe o destino: restore.sh $DB_ID remote <destino> <arquivo>}"
        FNAME="${4:?informe o nome do arquivo: restore.sh $DB_ID remote <destino> <arquivo>}"
        download_from_destination "$DEST_NAME" "$FNAME"
        FILEPATH="${BACKUP_DIR}/${FNAME}"
        ;;
    *)
        echo "uso: restore.sh <id> [local <arquivo> | latest [destino] | remote <destino> <arquivo>]" >&2
        exit 1
        ;;
esac

if [ -f "${FILEPATH}.sha256" ]; then
    EXPECTED=$(cat "${FILEPATH}.sha256")
    ACTUAL=$(sha256sum "$FILEPATH" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "[restore] ERRO: checksum não confere (esperado ${EXPECTED}, obtido ${ACTUAL})" >&2
        exit 1
    fi
    echo "[restore] checksum OK"
fi

echo "[restore] restaurando '${FILEPATH}' em ${PG_HOST}:${PG_PORT}/${PG_DATABASE} (usuário ${PG_USER})"
echo "[restore] ATENÇÃO: isso vai recriar objetos existentes no banco de destino."
read -r -p "Confirma restauração em '${PG_DATABASE}'? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "[restore] cancelado pelo usuário"; exit 0; }

# --clean --if-exists: apaga objetos antes de recriar (restore idempotente)
# -j 4: restaura em paralelo (ajuste conforme CPU disponível)
RESTORE_LOG=$(mktemp)
pg_restore_tolerant "$RESTORE_LOG" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" \
    --clean --if-exists --no-owner --no-privileges -j 4 "$FILEPATH"
RC=$?

case $RC in
    0)
        echo "[restore] restauração concluída com sucesso"
        ;;
    2)
        echo "[restore] restauração concluída com sucesso (aviso: o servidor de destino não reconhece algum parâmetro de sessão do dump — comum quando o servidor é mais antigo que o cliente pg_dump usado; os dados foram restaurados normalmente):"
        cat "$RESTORE_LOG" >&2
        ;;
    *)
        echo "[restore] pg_restore terminou com erros reais:" >&2
        cat "$RESTORE_LOG" >&2
        rm -f "$RESTORE_LOG"
        exit 1
        ;;
esac
rm -f "$RESTORE_LOG"
