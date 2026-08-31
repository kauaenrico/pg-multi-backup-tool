#!/bin/bash
# Funções compartilhadas por entrypoint.sh, backup.sh, restore.sh, verify.sh e list.sh.
# Este arquivo é sempre carregado via `. lib/common.sh`, nunca executado diretamente.

: "${CONFIG_FILE:=/app/config/databases.yml}"
: "${BACKUP_DIR:=/backups}"

log() {
    local id="$1"; shift
    echo "[${id}] $(date -Iseconds) $*"
}

# Envia uma notificação via webhook (Slack por padrão; WEBHOOK_FORMAT=discord
# troca a chave do JSON de "text" para "content"). Nunca falha o chamador.
send_webhook() {
    local url="$1" msg="$2"
    [ -n "$url" ] || return 0
    local body
    case "${WEBHOOK_FORMAT:-slack}" in
        discord) body=$(jq -cn --arg c "$msg" '{content:$c}') ;;
        *)       body=$(jq -cn --arg t "$msg" '{text:$t}') ;;
    esac
    curl -fsS -m 10 -X POST -H "Content-Type: application/json" -d "$body" "$url" >/dev/null 2>&1 || true
}

fail_db() {
    local id="$1" msg="$2" webhook="${3:-}"
    log "$id" "ERRO: $msg"
    send_webhook "$webhook" "❌ [${id}] backup FALHOU: ${msg}"
    exit 1
}

require_db_exists() {
    local id="$1" found
    found=$(DB_ID="$id" yq e '(.databases[] | select(.id == strenv(DB_ID)) | .id) // ""' "$CONFIG_FILE")
    [ -n "$found" ] || { echo "[erro] id '$id' não encontrado em $CONFIG_FILE" >&2; exit 1; }
}

# db_get <id> <caminho-relativo-iniciando-com-.> [default]
# Busca o campo dentro do objeto do banco identificado por <id>; se ausente,
# cai para o mesmo caminho dentro de `defaults:`; se ainda ausente, usa [default].
#
# IMPORTANTE: nunca use aqui o operador `//` do yq/jq como fallback (`campo //
# "default"`) — ele trata `false` como "vazio" igual a null/ausente, então um
# `verify.checksum: false` explícito seria silenciosamente revertido para o
# default. Em vez disso, lemos o valor cru e só caímos no default quando ele
# for de fato ausente (string vazia ou literal "null").
db_get() {
    local id="$1" relpath="$2" default="${3:-}" val
    val=$(DB_ID="$id" yq e "(.databases[] | select(.id == strenv(DB_ID))${relpath})" "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        val=$(yq e "(.defaults${relpath})" "$CONFIG_FILE" 2>/dev/null)
    fi
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        val="$default"
    fi
    printf '%s' "$val"
}

# Imprime um objeto JSON compacto por linha, um por destino configurado do banco <id>.
db_destinations_json() {
    local id="$1"
    DB_ID="$id" yq e -o=json "(.databases[] | select(.id == strenv(DB_ID)) | .destinations // [])" "$CONFIG_FILE" | jq -c '.[]'
}

# find_destination <id> <nome-do-destino> -> JSON do destino, vazio se não achar.
find_destination() {
    local id="$1" name="$2"
    db_destinations_json "$id" | jq -c --arg n "$name" 'select(.name == $n)'
}

# pg_restore_tolerant <logfile> <args-do-pg_restore...>
# Roda pg_restore normalmente, mas classifica o resultado em vez de só olhar
# o exit code. Dumps gerados pelo cliente pg_dump da imagem "postgres:latest"
# (usada de propósito para ter um único binário compatível com vários
# servidores-alvo mais antigos) incluem no preâmbulo comandos SET para GUCs
# de sessão que só existem em versões novas do Postgres (ex.: o Postgres 17
# introduziu `transaction_timeout`). Ao restaurar num servidor mais antigo,
# pg_restore tenta esse SET, o servidor rejeita com "unrecognized
# configuration parameter", e o próprio pg_restore já ignora esse erro e
# segue restaurando o resto normalmente — mas ainda assim sai com exit code
# != 0. Sem esse tratamento, TODO restore contra um servidor pré-17 seria
# reportado como falha mesmo com os dados restaurados com sucesso.
# Retorna: 0 = sucesso limpo | 2 = sucesso, mas com aviso benigno de
# compatibilidade de versão (ver $logfile) | 1 = falha real.
pg_restore_tolerant() {
    local logfile="$1"; shift
    pg_restore "$@" >"$logfile" 2>&1
    local rc=$?
    [ $rc -eq 0 ] && return 0

    local real_errors benign_errors
    real_errors=$(grep -c '^pg_restore: error:' "$logfile" 2>/dev/null || echo 0)
    benign_errors=$(grep -c 'unrecognized configuration parameter' "$logfile" 2>/dev/null || echo 0)

    if [ "$real_errors" -gt 0 ] && [ "$real_errors" -eq "$benign_errors" ]; then
        return 2
    fi
    return 1
}

resolve_pg_env() {
    local id="$1"
    PG_HOST=$(db_get "$id" ".connection.host")
    PG_PORT=$(db_get "$id" ".connection.port" "5432")
    PG_USER=$(db_get "$id" ".connection.user" "postgres")
    PG_DATABASE=$(db_get "$id" ".connection.database")
    local pwvar
    pwvar=$(db_get "$id" ".connection.password_env")
    [ -n "$PG_HOST" ] && [ -n "$PG_DATABASE" ] && [ -n "$pwvar" ] \
        || { log "$id" "ERRO: configuração incompleta (connection.host/database/password_env)"; return 1; }
    PGPASSWORD="${!pwvar:-}"
    [ -n "$PGPASSWORD" ] || { log "$id" "ERRO: variável de ambiente '${pwvar}' (senha) não definida"; return 1; }
    export PGPASSWORD
}

# local_md5_hex <arquivo> -> MD5 em hex minúsculo
local_md5_hex() {
    md5sum "$1" | awk '{print $1}'
}

# oci_par_remote_md5_hex <url-do-objeto-na-par>
# HEAD na PAR e conversão do header "content-md5" (base64, como toda a family
# de APIs de object storage retorna) pra hex, comparável a `md5sum`. Não baixa
# o corpo do objeto — é só isso que faz esse checksum "custar zero rede extra".
oci_par_remote_md5_hex() {
    local url="$1" b64
    b64=$(curl -sS -I "$url" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-md5"{print $2}')
    [ -n "$b64" ] || return 1
    echo "$b64" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

# upload_local <id> <destino-json> <arquivo> <arquivo-sha256-ou-vazio> <verificar-tamanho:true|false> <verificar-checksum:true|false>
# Copia o dump (e o .sha256, se houver) para outro caminho dentro do próprio
# container — útil para um segundo disco/NAS/mount montado à parte do
# BACKUP_DIR de staging (que já tem sua própria retenção via retention.local_days,
# independente disso). O "path" precisa estar montado como volume no compose.
upload_local() {
    local id="$1" dest="$2" filepath="$3" shafile="$4" verify="$5" verify_checksum="${6:-false}"
    local name path fname
    name=$(echo "$dest" | jq -r '.name')
    path=$(echo "$dest" | jq -r '.path')
    [ -n "$path" ] && [ "$path" != "null" ] || { log "$id" "ERRO: destino '${name}' (local) sem 'path' configurado"; return 1; }
    fname=$(basename "$filepath")

    log "$id" "copiando para destino '${name}' (local: ${path})"
    if ! mkdir -p "$path"; then
        log "$id" "ERRO: não foi possível criar o diretório '${path}' do destino '${name}'"
        return 1
    fi
    if ! cp "$filepath" "${path}/${fname}"; then
        log "$id" "ERRO: falha ao copiar para destino '${name}' (${path})"
        return 1
    fi
    if [ -n "$shafile" ]; then
        cp "$shafile" "${path}/$(basename "$shafile")" 2>/dev/null \
            || log "$id" "aviso: falha ao copiar checksum para '${name}' (não é fatal)"
    fi

    if [ "$verify" = "true" ]; then
        local local_size copied_size
        local_size=$(stat -c%s "$filepath")
        copied_size=$(stat -c%s "${path}/${fname}" 2>/dev/null)
        if [ "$copied_size" != "$local_size" ]; then
            log "$id" "ERRO: verificação de cópia falhou em '${name}' (origem=${local_size} destino=${copied_size:-desconhecido})"
            return 1
        fi
        log "$id" "verificação de cópia OK em '${name}' (${local_size} bytes)"
    fi
    if [ "$verify_checksum" = "true" ]; then
        local local_md5 copied_md5
        local_md5=$(local_md5_hex "$filepath")
        copied_md5=$(local_md5_hex "${path}/${fname}")
        if [ "$local_md5" != "$copied_md5" ]; then
            log "$id" "ERRO: checksum não confere em '${name}' (origem=${local_md5} cópia=${copied_md5})"
            return 1
        fi
        log "$id" "checksum OK em '${name}' (md5 ${local_md5})"
    fi
    return 0
}

# upload_rclone <id> <destino-json> <arquivo> <arquivo-sha256-ou-vazio> <verificar-tamanho:true|false> <verificar-checksum:true|false>
upload_rclone() {
    local id="$1" dest="$2" filepath="$3" shafile="$4" verify="$5" verify_checksum="${6:-false}"
    local name remote bucket prefix remote_path fname
    name=$(echo "$dest" | jq -r '.name')
    remote=$(echo "$dest" | jq -r '.remote')
    bucket=$(echo "$dest" | jq -r '.bucket')
    prefix=$(echo "$dest" | jq -r '.prefix // ""')
    remote_path="${remote}:${bucket}/${prefix}"
    fname=$(basename "$filepath")

    log "$id" "enviando para destino '${name}' (${remote_path})"
    if ! rclone copy "$filepath" "$remote_path" --checksum --s3-no-check-bucket; then
        log "$id" "ERRO: falha ao enviar para destino '${name}' (${remote_path})"
        return 1
    fi
    if [ -n "$shafile" ]; then
        rclone copy "$shafile" "$remote_path" --s3-no-check-bucket \
            || log "$id" "aviso: falha ao enviar checksum para '${name}' (não é fatal)"
    fi

    if [ "$verify" = "true" ]; then
        local local_size remote_size
        local_size=$(stat -c%s "$filepath")
        remote_size=$(rclone lsjson "$remote_path" 2>/dev/null | jq -r --arg f "$fname" '.[] | select(.Name==$f) | .Size')
        if [ "$remote_size" != "$local_size" ]; then
            log "$id" "ERRO: verificação de upload falhou em '${name}' (local=${local_size} remoto=${remote_size:-desconhecido})"
            return 1
        fi
        log "$id" "verificação de upload OK em '${name}' (${local_size} bytes)"
    fi
    if [ "$verify_checksum" = "true" ]; then
        local local_md5 remote_md5
        local_md5=$(local_md5_hex "$filepath")
        # rclone hashsum lê o MD5 do ETag do backend via HEAD — não baixa o
        # arquivo. Só é confiável pra uploads em uma parte só (sem multipart);
        # se o backend não souber informar, retorna vazio e a gente só avisa.
        remote_md5=$(rclone hashsum md5 "${remote_path}${fname}" --s3-no-check-bucket 2>/dev/null | awk '{print $1}')
        if [ -z "$remote_md5" ]; then
            log "$id" "aviso: '${name}' não retornou MD5 pra verificação de checksum (não é fatal)"
        elif [ "$remote_md5" != "$local_md5" ]; then
            log "$id" "ERRO: checksum não confere em '${name}' (local=${local_md5} remoto=${remote_md5})"
            return 1
        else
            log "$id" "checksum OK em '${name}' (md5 ${local_md5}, sem re-baixar o arquivo)"
        fi
    fi
    return 0
}

# upload_oci_par <id> <destino-json> <arquivo> <arquivo-sha256-ou-vazio> <verificar-tamanho:true|false> <verificar-checksum:true|false>
# Espera um PAR "bucket-level" com permissão de escrita (ObjectReadWrite/AnyObjectWrite);
# o nome do arquivo é anexado à URL do PAR.
upload_oci_par() {
    local id="$1" dest="$2" filepath="$3" shafile="$4" verify="$5" verify_checksum="${6:-false}"
    local name var url fname http_code
    name=$(echo "$dest" | jq -r '.name')
    var=$(echo "$dest" | jq -r '.par_url_env')
    url="${!var:-}"
    [ -n "$url" ] || { log "$id" "ERRO: variável '${var}' (PAR da OCI) não definida para destino '${name}'"; return 1; }
    url="${url%/}"
    fname=$(basename "$filepath")

    log "$id" "enviando para destino '${name}' (OCI PAR) objeto ${fname}"
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$filepath" "${url}/${fname}")
    if [ "$http_code" != "200" ]; then
        log "$id" "ERRO: PUT na OCI (destino '${name}') retornou HTTP ${http_code}"
        return 1
    fi
    if [ -n "$shafile" ]; then
        curl -sS -o /dev/null -X PUT --data-binary @"$shafile" "${url}/$(basename "$shafile")" \
            || log "$id" "aviso: falha ao enviar checksum para '${name}' (não é fatal)"
    fi

    if [ "$verify" = "true" ]; then
        local local_size remote_size
        local_size=$(stat -c%s "$filepath")
        remote_size=$(curl -sS -I "${url}/${fname}" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')
        if [ "$remote_size" != "$local_size" ]; then
            log "$id" "ERRO: verificação de upload falhou em '${name}' (local=${local_size} remoto=${remote_size:-desconhecido}; a PAR precisa permitir leitura para verificar)"
            return 1
        fi
        log "$id" "verificação de upload OK em '${name}' (${local_size} bytes)"
    fi
    if [ "$verify_checksum" = "true" ]; then
        local local_md5 remote_md5
        local_md5=$(local_md5_hex "$filepath")
        remote_md5=$(oci_par_remote_md5_hex "${url}/${fname}")
        if [ -z "$remote_md5" ]; then
            log "$id" "aviso: '${name}' não retornou content-md5 pra verificação de checksum (não é fatal)"
        elif [ "$remote_md5" != "$local_md5" ]; then
            log "$id" "ERRO: checksum não confere em '${name}' (local=${local_md5} remoto=${remote_md5})"
            return 1
        else
            log "$id" "checksum OK em '${name}' (md5 ${local_md5}, sem re-baixar o arquivo)"
        fi
    fi
    return 0
}

# oci_par_list_names <par_base_url>
# Lista os nomes de objetos via GET na raiz da PAR. Só funciona em PARs de
# nível de bucket criadas com "Enable Object Listing" habilitado na OCI — sem
# essa opção a OCI recusa o GET de listagem (mas PUT/GET/HEAD de objeto
# individual continuam funcionando normalmente). Não pagina resultados: buckets
# com muito mais objetos que o limite padrão de página da OCI podem não
# aparecer inteiros aqui — mantenha prefixos/buckets por projeto e uma
# retenção razoável para não esbarrar nisso.
oci_par_list_names() {
    local url="$1"
    curl -sS "${url%/}/" 2>/dev/null | jq -r '.objects[]?.name // empty' 2>/dev/null
}

# apply_remote_retention <id>
apply_remote_retention() {
    local id="$1" remote_days
    remote_days=$(db_get "$id" ".retention.remote_days" "30")
    while IFS= read -r dest; do
        [ -z "$dest" ] && continue
        local type
        type=$(echo "$dest" | jq -r '.type')
        case "$type" in
            s3|r2) apply_rclone_retention "$id" "$dest" "$remote_days" ;;
            oci_par) apply_oci_par_retention "$id" "$dest" "$remote_days" ;;
            local) apply_local_dest_retention "$id" "$dest" "$remote_days" ;;
        esac
    done < <(db_destinations_json "$id")
}

# apply_local_dest_retention <id> <destino-json> <dias>
# Mesmo critério do BACKUP_DIR de staging (mtime do arquivo), só que aplicado
# ao "path" do destino local.
apply_local_dest_retention() {
    local id="$1" dest="$2" remote_days="$3" name path
    name=$(echo "$dest" | jq -r '.name')
    path=$(echo "$dest" | jq -r '.path')
    [ -n "$path" ] && [ -d "$path" ] || return
    find "$path" -maxdepth 1 -name "${id}_*" -mtime "+${remote_days}" -print -delete \
        | while read -r f; do log "$id" "removido backup antigo em '${name}': $f"; done
}

apply_rclone_retention() {
    local id="$1" dest="$2" remote_days="$3" name remote bucket prefix remote_path
    name=$(echo "$dest" | jq -r '.name')
    remote=$(echo "$dest" | jq -r '.remote')
    bucket=$(echo "$dest" | jq -r '.bucket')
    prefix=$(echo "$dest" | jq -r '.prefix // ""')
    remote_path="${remote}:${bucket}/${prefix}"
    rclone delete "$remote_path" --min-age "${remote_days}d" --s3-no-check-bucket --include "${id}_*" \
        || log "$id" "aviso: falha ao aplicar retenção remota em '${name}' (não é fatal)"
}

# apply_oci_par_retention <id> <destino-json> <dias>
# A idade de cada objeto é lida do próprio nome do arquivo (formato
# "<id>_AAAA-MM-DD_HH-MM-SS.ext" gerado pelo backup.sh), não de metadado do
# servidor. O DELETE só funciona se a PAR tiver sido criada com permissão de
# exclusão (bucket-level, tipo "leitura/escrita/delete") — caso contrário cada
# falha de remoção vira só um aviso, igual ao comportamento já existente para
# falhas de retenção em s3/r2.
apply_oci_par_retention() {
    local id="$1" dest="$2" remote_days="$3" name var url now_epoch
    name=$(echo "$dest" | jq -r '.name')
    var=$(echo "$dest" | jq -r '.par_url_env')
    url="${!var:-}"
    [ -n "$url" ] || { log "$id" "aviso: variável '${var}' (PAR) não definida, pulando retenção remota em '${name}'"; return; }
    url="${url%/}"
    now_epoch=$(date +%s)

    oci_par_list_names "$url" | grep -E "^${id}_[0-9]{4}-[0-9]{2}-[0-9]{2}_" | while IFS= read -r objname; do
        local datepart file_epoch age_days http_code
        datepart=$(echo "$objname" | sed -E "s/^${id}_([0-9]{4}-[0-9]{2}-[0-9]{2})_.*/\1/")
        file_epoch=$(date -d "$datepart" +%s 2>/dev/null) || continue
        age_days=$(( (now_epoch - file_epoch) / 86400 ))
        [ "$age_days" -gt "$remote_days" ] || continue
        http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "${url}/${objname}")
        if echo "$http_code" | grep -qE '^20[0-9]$'; then
            log "$id" "removido backup remoto antigo em '${name}': ${objname}"
        else
            log "$id" "aviso: não foi possível remover '${objname}' em '${name}' (HTTP ${http_code}; a PAR pode não ter permissão de delete) — não é fatal"
        fi
    done
}

# run_test_restore <id> <arquivo>
# Cria um banco temporário no mesmo servidor, restaura o dump nele e apaga em seguida.
# Exige privilégio CREATEDB no usuário configurado. Opt-in via verify.test_restore: true.
run_test_restore() {
    local id="$1" filepath="$2" verify_db logfile
    resolve_pg_env "$id" || return 1
    verify_db="bkpverify_${id//-/_}_$$"
    logfile="/tmp/${id}-test-restore.log"

    log "$id" "criando banco temporário '${verify_db}' para teste de restore"
    if ! createdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" "$verify_db" 2>"$logfile"; then
        log "$id" "ERRO: não foi possível criar banco de verificação (veja ${logfile})"
        return 1
    fi

    pg_restore_tolerant "$logfile" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$verify_db" --no-owner --no-privileges "$filepath"
    local rc=$?
    if [ $rc -eq 1 ]; then
        log "$id" "ERRO: restore de teste falhou (veja ${logfile})"
        dropdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" "$verify_db" 2>/dev/null
        return 1
    fi
    dropdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" "$verify_db"
    if [ $rc -eq 2 ]; then
        log "$id" "teste de restore concluído com sucesso (aviso benigno: servidor de destino não reconhece algum parâmetro de sessão do dump, comum quando o servidor é mais antigo que o cliente pg_dump usado)"
    else
        log "$id" "teste de restore concluído com sucesso; banco temporário removido"
    fi
    return 0
}
