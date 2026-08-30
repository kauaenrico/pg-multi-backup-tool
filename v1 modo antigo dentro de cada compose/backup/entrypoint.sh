#!/bin/bash
set -euo pipefail

: "${R2_ACCOUNT_ID:?defina R2_ACCOUNT_ID no .env}"
: "${R2_ACCESS_KEY_ID:?defina R2_ACCESS_KEY_ID no .env}"
: "${R2_SECRET_ACCESS_KEY:?defina R2_SECRET_ACCESS_KEY no .env}"
: "${R2_BUCKET:?defina R2_BUCKET no .env}"

mkdir -p /root/.config/rclone

cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
region = auto
acl = private
EOF

chmod 600 /root/.config/rclone/rclone.conf

echo "[entrypoint] $(date -Iseconds) container de backup iniciado. Cron ativo:"
cat /etc/crontabs/root

# -f = roda em primeiro plano. -l 6 = loglevel "info": mostra no `docker
# logs` quando cada job dispara (linha "FILE ... USER root PID N cmd"),
# sem o modo debug (-d) — que nesse dcron não é "nível 8", é um booleano
# que liga um trace interno do laço de polling a cada 60s pra sempre
# ("Wakeup dt=60" / "TestJobs()"), enchendo o log sem nenhum sinal útil.
exec crond -f -l 6
