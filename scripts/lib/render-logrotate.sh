#!/bin/bash
# Gera /etc/logrotate.d/pg-backup a partir de LOG_DIR (não é fixo no Dockerfile
# porque LOG_DIR pode ser sobrescrito via env var no compose, igual CONFIG_FILE
# e BACKUP_DIR já são).
#
# rotate 14: mantém 14 dias de log rotacionado por banco, comprimido. Não há
# processo de longa duração escrevendo continuamente no arquivo (cada
# execução de backup.sh/restore.sh/etc. abre, escreve e fecha), então o
# rename-based rotate padrão do logrotate é seguro — não precisa de
# `copytruncate`.
#
# `su root root`: testado sem isso e o logrotate recusa rotacionar quando
# LOG_DIR é um bind mount com permissão "world-writable" (comum dependendo de
# como o host monta o volume) — é uma checagem de segurança do próprio
# logrotate contra rotacionar como root num diretório que outros usuários
# também podem escrever. Como o container inteiro já roda como root mesmo,
# declarar isso explicitamente é seguro aqui e resolve.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/common.sh"

mkdir -p /var/lib/logrotate

cat > /etc/logrotate.d/pg-backup <<EOF
${LOG_DIR}/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    su root root
}
EOF
