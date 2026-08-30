#!/bin/bash
# Verificação sob demanda de um arquivo de dump já existente localmente
# (baixe primeiro com restore.sh se precisar de um backup remoto).
#
# Uso: verify.sh <id> --file <caminho> [--test-restore]
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

DB_ID="${1:?uso: verify.sh <id> --file <caminho> [--test-restore]}"
shift
require_db_exists "$DB_ID"

FILEPATH=""
DO_TEST_RESTORE="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --file) FILEPATH="${2:?}"; shift 2 ;;
        --test-restore) DO_TEST_RESTORE="true"; shift ;;
        *) echo "opção desconhecida: $1" >&2; exit 1 ;;
    esac
done

[ -n "$FILEPATH" ] || { echo "uso: verify.sh <id> --file <caminho> [--test-restore]" >&2; exit 1; }
[ -f "$FILEPATH" ] || { echo "ERRO: arquivo não encontrado: $FILEPATH" >&2; exit 1; }

echo "[verify] checando '${FILEPATH}'"

if [ -f "${FILEPATH}.sha256" ]; then
    EXPECTED=$(cat "${FILEPATH}.sha256")
    ACTUAL=$(sha256sum "$FILEPATH" | awk '{print $1}')
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        echo "[verify] checksum OK"
    else
        echo "[verify] ERRO: checksum não confere (esperado ${EXPECTED}, obtido ${ACTUAL})" >&2
        exit 1
    fi
else
    echo "[verify] aviso: nenhum arquivo .sha256 encontrado ao lado do dump, pulando checagem de checksum"
fi

case "$FILEPATH" in
    *.dump|*.dir)
        if pg_restore --list "$FILEPATH" >/dev/null 2>&1; then
            echo "[verify] checagem estrutural (pg_restore --list) OK"
        else
            echo "[verify] ERRO: pg_restore --list falhou, dump corrompido/inválido" >&2
            exit 1
        fi
        ;;
    *)
        echo "[verify] formato plain/desconhecido, pulando checagem estrutural"
        ;;
esac

if [ "$DO_TEST_RESTORE" = "true" ]; then
    run_test_restore "$DB_ID" "$FILEPATH" || exit 1
fi

echo "[verify] tudo certo com '${FILEPATH}'"
