#!/bin/bash
# Gera /root/.config/rclone/rclone.conf a partir da seção `remotes:` do CONFIG_FILE.
# Cada remote referencia nomes de variáveis de ambiente (nunca valores em texto puro
# no YAML) resolvidas aqui a partir do .env carregado no container.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/common.sh"

CONF_DIR="/root/.config/rclone"
CONF="${CONF_DIR}/rclone.conf"

mkdir -p "$CONF_DIR"
: > "$CONF"

yq e -o=json '.remotes // []' "$CONFIG_FILE" | jq -c '.[]' | while IFS= read -r remote; do
    name=$(echo "$remote" | jq -r '.name')
    provider=$(echo "$remote" | jq -r '.provider // ""')
    region=$(echo "$remote" | jq -r '.region // ""')
    endpoint_var=$(echo "$remote" | jq -r '.endpoint_env // ""')
    ak_var=$(echo "$remote" | jq -r '.access_key_id_env')
    sk_var=$(echo "$remote" | jq -r '.secret_access_key_env')

    endpoint=""
    [ -n "$endpoint_var" ] && endpoint="${!endpoint_var:-}"
    access_key="${!ak_var:-}"
    secret_key="${!sk_var:-}"

    if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        echo "[rclone-conf] AVISO: remote '${name}' sem credenciais (${ak_var}/${sk_var} não definidas), pulando" >&2
        continue
    fi

    {
        echo "[${name}]"
        echo "type = s3"
        [ -n "$provider" ] && echo "provider = ${provider}"
        [ -n "$region" ] && echo "region = ${region}"
        [ -n "$endpoint" ] && echo "endpoint = ${endpoint}"
        echo "access_key_id = ${access_key}"
        echo "secret_access_key = ${secret_key}"
        echo "acl = private"
        echo
    } >> "$CONF"
    echo "[rclone-conf] remote '${name}' configurado" >&2
done

chmod 600 "$CONF"
