#!/bin/bash
# Lista os bancos configurados em databases.yml em formato de tabela.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

DEFAULT_SCHEDULE=$(yq e '.defaults.schedule // "0 3 * * *"' "$CONFIG_FILE")

{
    printf 'ID\tHABILITADO\tHOST\tBANCO\tSCHEDULE\tDESTINOS\n'
    yq e -o=json '.databases // []' "$CONFIG_FILE" | jq -c '.[]' | while IFS= read -r db; do
        id=$(echo "$db" | jq -r '.id')
        enabled=$(echo "$db" | jq -r 'if .enabled == null then true else .enabled end')
        host=$(echo "$db" | jq -r '.connection.host // "-"')
        dbname=$(echo "$db" | jq -r '.connection.database // "-"')
        schedule=$(echo "$db" | jq -r '.schedule // empty')
        [ -n "$schedule" ] || schedule="${DEFAULT_SCHEDULE} (default)"
        destinations=$(echo "$db" | jq -r '[.destinations[]?.name] | join(",")')
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$enabled" "$host" "$dbname" "$schedule" "$destinations"
    done
} | column -t -s "$(printf '\t')"
