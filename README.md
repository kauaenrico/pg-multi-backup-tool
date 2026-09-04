# pg-multi-backup-tool

Serviço único de backup para múltiplos bancos Postgres — um container central,
configurado por um YAML, que faz backup/restore/verificação de vários projetos
ao mesmo tempo, cada um com seu próprio horário, retenção e destino(s) de
armazenamento. Substitui o modelo anterior (pasta `v1 modo antigo dentro de
cada compose/`), em que os scripts e o container de backup eram duplicados
dentro de cada projeto.

## Como funciona

- Um único container, construído a partir da imagem `postgres:latest` (usada
  só como *cliente* — `pg_dump`/`pg_restore`/`psql`). O protocolo de dump é
  retrocompatível, então esse cliente mais novo consegue fazer backup de
  servidores Postgres mais antigos sem precisar de uma imagem por versão.
- O container entra na(s) mesma(s) network(s) Docker que os projetos já usam
  e conecta em cada Postgres pelo nome do container/serviço (`host:porta`).
- Toda a configuração — quais bancos existem, horário de cada um, retenção,
  para onde enviar — fica em **um arquivo YAML** (`config/databases.yml`).
  Nenhum segredo fica em texto puro nesse arquivo: cada campo sensível é o
  *nome* de uma variável de ambiente, cujo valor vem do `.env`.
- O agendamento é feito com `cron` de verdade dentro do container: no start,
  o `entrypoint.sh` lê `databases.yml` e gera um crontab com uma linha por
  banco habilitado, cada uma rodando `backup.sh <id>`. **Bancos com o mesmo
  horário rodam de verdade em paralelo** — confirmado observando dois
  `pg_dump` simultâneos disparados pelo próprio cron, não só em teoria.
  O `cron` também só entrega aos jobs um ambiente mínimo (`HOME`/`PATH`/
  `SHELL`), sem nada do `.env` — por isso o crontab gerado inclui todas as
  variáveis de ambiente do container como linhas `VAR=valor`, senão toda
  senha/chave/URL referenciada via `*_env` ficaria invisível pro job quando
  o cron dispara sozinho (só funcionaria rodando manualmente via `docker
  compose exec`, que herda o ambiente do container de outro jeito).
- Upload é feito via `rclone` (qualquer backend S3-compatível: S3, Cloudflare
  R2, MinIO, B2 via API S3 etc.) ou via `curl` puro para uma **Pre-Authenticated
  Request (PAR)** da OCI Object Storage.
- Notificações são configuráveis por evento (início, sucesso, aviso, falha) e
  por canal (webhook Slack/Discord/genérico, Telegram, e-mail via SMTP, ntfy)
  — ver seção "Notificações" abaixo.

## Estrutura

```
config/
  databases.example.yml   # copie para databases.yml e edite
scripts/
  entrypoint.sh            # gera rclone.conf + crontab e sobe o cron em foreground
  backup.sh <id>            # dump -> checagens -> upload -> retenção
  resend.sh <id> ...         # reenvia um dump JÁ EXISTENTE local, sem rodar pg_dump de novo
  restore.sh <id> ...         # baixa e restaura um backup
  verify.sh <id> ...           # checagem avulsa de um arquivo já baixado
  list.sh                       # lista os bancos configurados
  lib/
    common.sh                   # funções compartilhadas
    render-rclone-conf.sh         # gera rclone.conf a partir de `remotes:`
    render-crontab.sh              # gera o crontab a partir de `databases:`
Dockerfile
docker-compose.yml
.env.example
```

## Configuração (`databases.yml`)

`config/databases.example.yml` (reproduzido aqui, sempre sincronizado com o
arquivo real) traz `defaults`, `remotes` e **3 bancos de exemplo**, cada um
variando um conjunto diferente de parâmetros pra cobrir, entre os três, quase
toda a superfície de configuração possível:

- **`app-simples`** — o mínimo indispensável: só os campos obrigatórios, tudo
  o resto herda de `defaults`. Um único destino na nuvem, **sem** nenhum
  destino `local` além do staging temporário que sempre existe.
- **`app-critico`** — todo campo sobrescrito (schedule, retenção, os 5 flags
  de `verify`, incluindo os dois opt-in) e backup replicado nos **4 tipos de
  destino ao mesmo tempo** (S3 + R2 + OCI PAR + disco local).
- **`app-legado`** — `format: plain` (em vez do `custom` default),
  `enabled: false` (fora do crontab automático, mas ainda rodável na mão) e
  um único destino, do tipo `local` — o espelho do `app-simples` (que não
  tinha nenhum `local`).

Notificações seguem a mesma lógica: `app-simples` herda o webhook de
`defaults`; `app-critico` sobrescreve com Telegram + e-mail + Discord, cada
canal num conjunto de eventos diferente; `app-legado` usa só um `ntfy` em
`on: [failure]`.

```yaml
defaults:
  schedule: "0 3 * * *"
  format: custom
  retention:
    local_days: 7
    remote_days: 30
  verify:
    structural_check: true
    checksum: true
    verify_upload: true
    checksum_after_upload: false
    test_restore: false
  notifications:
    - type: webhook
      format: slack
      url_env: DEFAULT_WEBHOOK_URL
      on: [failure, warning]

remotes:
  - name: r2-principal
    type: s3
    provider: Cloudflare
    endpoint_env: R2_ENDPOINT
    access_key_id_env: R2_ACCESS_KEY_ID
    secret_access_key_env: R2_SECRET_ACCESS_KEY

  - name: s3-aws-generico
    type: s3
    provider: AWS
    region: us-east-1
    access_key_id_env: AWS_ACCESS_KEY_ID
    secret_access_key_env: AWS_SECRET_ACCESS_KEY

databases:
  # 1) MÍNIMO POSSÍVEL — só os campos obrigatórios, resto herda de `defaults`.
  #    Único destino, na nuvem, sem nenhum "local".
  - id: app-simples
    connection:
      host: app-simples-postgres
      database: app_simples
      password_env: APP_SIMPLES_PGPASSWORD
    destinations:
      - name: r2-principal
        type: r2
        remote: r2-principal
        bucket: app-simples-backups
        prefix: app-simples/

  # 2) "CINTO E SUSPENSÓRIOS" — tudo sobrescrito, verificação máxima, backup
  #    nos 4 tipos de destino ao mesmo tempo.
  - id: app-critico
    enabled: true
    schedule: "15 2 * * *"
    format: custom
    connection:
      host: app-critico-postgres
      port: 5432
      user: postgres
      database: app_critico
      password_env: APP_CRITICO_PGPASSWORD
    retention:
      local_days: 14
      remote_days: 90
    verify:
      structural_check: true
      checksum: true
      verify_upload: true
      checksum_after_upload: true
      test_restore: true
    destinations:
      - name: s3-principal
        type: s3
        remote: s3-aws-generico
        bucket: app-critico-backups-primario
        prefix: app-critico/
      - name: r2-secundario
        type: r2
        remote: r2-principal
        bucket: app-critico-backups-secundario
        prefix: app-critico/
      - name: oci-arquivo-frio
        type: oci_par
        par_url_env: APP_CRITICO_OCI_PAR_URL
      - name: disco-secundario
        type: local
        path: /mnt/backup-secundario/app-critico/
    notifications:
      - type: telegram
        name: telegram-oncall
        bot_token_env: APP_CRITICO_TELEGRAM_BOT_TOKEN
        chat_id_env: APP_CRITICO_TELEGRAM_CHAT_ID
        on: [start, success, warning, failure]
      - type: email
        smtp_host_env: SMTP_HOST
        smtp_port_env: SMTP_PORT
        smtp_user_env: SMTP_USER
        smtp_password_env: SMTP_PASSWORD
        from_env: SMTP_FROM
        to_env: APP_CRITICO_EMAIL_TO
        on: [failure, warning]
      - type: webhook
        format: discord
        url_env: APP_CRITICO_DISCORD_WEBHOOK_URL
        on: [failure]

  # 3) PROJETO PAUSADO/LEGADO — format: plain, enabled: false, único destino
  #    e é "local" (o oposto do exemplo 1).
  - id: app-legado
    enabled: false
    format: plain
    connection:
      host: app-legado-postgres
      database: app_legado
      password_env: APP_LEGADO_PGPASSWORD
    destinations:
      - name: disco-secundario
        type: local
        path: /mnt/backup-secundario/app-legado/
    notifications:
      - type: ntfy
        url_env: APP_LEGADO_NTFY_URL
        priority: default
        on: [failure]
```

Cada `id` em `databases:` é a unidade atômica de agendamento/retenção/destino
— exatamente o "parametrizado banco a banco" pedido: dois bancos no mesmo
servidor Postgres viram duas entradas independentes.

### Referência completa de parâmetros

Qualquer campo de `defaults:` pode ser repetido dentro de um banco específico
(mesmo caminho) para sobrescrever só aquele banco; o que não for repetido
herda de `defaults:`, e o que não estiver em nenhum dos dois usa o "default
do código" indicado abaixo.

**`defaults:`** (raiz do YAML — os mesmos campos valem dentro de `databases[]`)

| Campo | Tipo | Default do código | Descrição |
|---|---|---|---|
| `schedule` | string (cron, 5 campos) | `0 3 * * *` | Horário do backup. **Bancos com o mesmo `schedule` disparam em paralelo** (o `cron` não enfileira) — se tiver muitos bancos, considere escalonar os horários (`03:00`, `03:10`, `03:20`...) pra não competir por CPU/rede no mesmo instante. |
| `format` | `custom` \| `plain` | `custom` | Formato do `pg_dump` (`-Fc`/`-Fp`). Com `plain` a checagem estrutural é pulada (`pg_restore --list` não existe pra SQL puro). **`directory` (`-Fd`) não é suportado ainda** — testado e confirmado quebrado: gera múltiplos arquivos numa pasta, e checksum/upload/verificação/retenção assumem hoje "um dump = um arquivo só" em todo o pipeline. Fica de fora até isso ser implementado de verdade. |
| `retention.local_days` | inteiro | `7` | Dias que o dump fica no `BACKUP_DIR` de staging (`/backups`) antes de ser apagado. |
| `retention.remote_days` | inteiro | `30` | Dias até apagar de **cada** destino em `destinations:` — vale para `s3`, `r2`, `oci_par` (se a PAR permitir delete) e `local`. |
| `verify.structural_check` | boolean | `true` | `pg_restore --list` no dump logo após gerá-lo, antes do upload. |
| `verify.checksum` | boolean | `true` | Gera `<arquivo>.sha256` e envia junto a cada destino. |
| `verify.verify_upload` | boolean | `true` | Confere o tamanho do arquivo no destino logo após o envio. |
| `verify.checksum_after_upload` | boolean | `false` | Confere um MD5 real do destino contra o local, sem re-baixar (lê `ETag`/`content-md5` via `HEAD`). Ver detalhes na seção "Verificações feitas em todo backup". |
| `verify.test_restore` | boolean | `false` | Restore completo num banco descartável no mesmo servidor (`createdb`/`pg_restore`/`dropdb`). Exige `CREATEDB` no `connection.user`; mais caro, por isso opt-in. |

**`remotes[]`** (raiz do YAML — remotes reutilizáveis do rclone, usados por destinos `type: s3`/`type: r2`)

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `name` | string | Sim | Referenciado por `destinations[].remote`. |
| `type` | string | Sim | Hoje só `s3` é escrito pelo `render-rclone-conf.sh` — cobre qualquer backend que fale o protocolo S3 (AWS S3, Cloudflare R2, MinIO, Backblaze B2 via API S3 etc.). |
| `provider` | string | Não | Dica pro rclone (`AWS`, `Cloudflare`, `Minio`, `Other`...). |
| `region` | string | Não | Região S3 (ex.: `us-east-1`); ignorado por backends sem conceito de região (R2, por ex.). |
| `endpoint_env` | string | Depende | Nome da env var com a URL do endpoint. Obrigatório pra qualquer backend que não seja AWS S3 "de verdade" (R2, MinIO...). |
| `access_key_id_env` | string | Sim | Nome da env var com o Access Key ID. |
| `secret_access_key_env` | string | Sim | Nome da env var com o Secret Access Key. |

**`databases[]`** (raiz do YAML — um item por banco)

| Campo | Tipo | Obrigatório | Default | Descrição |
|---|---|---|---|---|
| `id` | string | Sim | — | Identificador único; vira prefixo do nome do arquivo (`<id>_AAAA-MM-DD_HH-MM-SS.ext`) e é o argumento passado para `backup.sh`/`restore.sh`/`verify.sh`. |
| `enabled` | boolean | Não | `true` | `false` tira o banco do crontab gerado (ainda dá pra rodar `backup.sh <id>` manualmente). |
| `schedule` | string (cron) | Não | herda de `defaults` | Override por banco. |
| `format` | string | Não | herda de `defaults` | Override por banco. |
| `connection` | objeto | Sim | — | Ver tabela abaixo. |
| `retention` | objeto | Não | herda de `defaults` | Mesmos campos `local_days`/`remote_days`, por banco. |
| `verify` | objeto | Não | herda de `defaults` | Mesmos 5 campos de verificação, por banco. |
| `destinations` | array (≥1) | Sim | — | Ver tabela abaixo. Sem nenhum item, o backup falha de propósito. |
| `notifications` | array | Não | herda de `defaults.notifications` (tudo ou nada, sem merge campo a campo) | Ver seção "Notificações" abaixo. |

**`databases[].connection`**

| Campo | Tipo | Obrigatório | Default | Descrição |
|---|---|---|---|---|
| `host` | string | Sim | — | Hostname resolvível na network Docker (nome do container/serviço do Postgres alvo). |
| `port` | inteiro | Não | `5432` | Porta do Postgres. |
| `user` | string | Não | `postgres` | Usuário do `pg_dump`/`pg_restore`; precisa de `CREATEDB` se `verify.test_restore: true`. |
| `database` | string | Sim | — | Nome do banco a ser copiado. |
| `password_env` | string | Sim | — | Nome da env var (do `.env`) com a senha desse usuário. |

**`databases[].destinations[]`** — campos comuns a todo item:

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `name` | string | Sim | Identifica o destino em `restore.sh ... latest/remote <name> ...`, nos logs e no `list.sh`. |
| `type` | `s3` \| `r2` \| `oci_par` \| `local` | Sim | Define quais campos abaixo se aplicam. |

Campos extras por `type`:

| `type` | Campo | Obrigatório | Descrição |
|---|---|---|---|
| `s3` / `r2` | `remote` | Sim | Nome de um remote declarado em `remotes:`. |
| `s3` / `r2` | `bucket` | Sim | Nome do bucket. |
| `s3` / `r2` | `prefix` | Não | Prefixo/"pasta" dentro do bucket (ex.: `meu-projeto/`). |
| `oci_par` | `par_url_env` | Sim | Nome da env var com a URL da PAR (nível de bucket — ver requisitos de permissão na seção de tipos de destino, acima). |
| `local` | `path` | Sim | Caminho absoluto **dentro do container** onde copiar o dump; precisa estar montado como volume no `docker-compose.yml`. |

**`databases[].notifications[]`** (ou `defaults.notifications[]`) — campos comuns a todo item:

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `type` | `webhook` \| `telegram` \| `email` \| `ntfy` | Sim | Define quais campos abaixo se aplicam. |
| `name` | string | Não | Só pra identificar o canal nos logs; default é o próprio `type`. |
| `on` | array de `start`\|`success`\|`warning`\|`failure` | Não | Em quais eventos esse canal dispara. **Default: `[failure]`** — se quiser confirmação de sucesso ou do início do backup, precisa adicionar explicitamente. |

Campos extras por `type` (ver seção "Notificações" para detalhes de cada canal):

| `type` | Campo | Obrigatório | Descrição |
|---|---|---|---|
| `webhook` | `url_env` | Sim | Nome da env var com a URL do webhook. |
| `webhook` | `format` | Não | `slack` (`{"text":...}`, default) \| `discord` (`{"content":...}`) \| `generic` (mesmo formato do slack). |
| `telegram` | `bot_token_env` | Sim | Nome da env var com o token do bot (via [@BotFather](https://t.me/BotFather)). |
| `telegram` | `chat_id_env` | Sim | Nome da env var com o `chat_id` de destino. |
| `email` | `smtp_host_env` | Sim | Nome da env var com o host SMTP. |
| `email` | `smtp_port_env` | Não | Nome da env var com a porta; sem isso, `587` (STARTTLS). |
| `email` | `smtp_user_env` | Sim | Nome da env var com o usuário SMTP. |
| `email` | `smtp_password_env` | Sim | Nome da env var com a senha SMTP. |
| `email` | `from_env` | Sim | Nome da env var com o remetente (`From:`). |
| `email` | `to_env` | Sim | Nome da env var com o(s) destinatário(s). |
| `ntfy` | `url_env` | Sim | Nome da env var com a URL completa do tópico (ex.: `https://ntfy.sh/meu-topico`). |
| `ntfy` | `priority` | Não | `min`\|`low`\|`default`\|`high`\|`urgent` (não é `*_env` — vai direto no YAML, não é segredo). |

**Fora do YAML** (variáveis de ambiente lidas direto pelo container, via `.env`/compose `environment:`):

| Variável | Default | Descrição |
|---|---|---|
| `CONFIG_FILE` | `/app/config/databases.yml` | Caminho do YAML dentro do container. |
| `BACKUP_DIR` | `/backups` | Diretório de staging dos dumps. |
| `TZ` | `America/Sao_Paulo` | Timezone usado pelo `cron` para interpretar os `schedule`. |

### Tipos de destino suportados hoje

- **`s3`** / **`r2`** — via `rclone`, para qualquer remote S3-compatível
  declarado em `remotes:`. Suporta upload, download, listagem (`latest`) e
  retenção remota automática (`rclone delete --min-age`).
- **`oci_par`** — Pre-Authenticated Request da OCI Object Storage. Sem SDK,
  sem chaves de API: o script faz `curl -X PUT`/`GET`/`DELETE` direto na URL
  da PAR. Crie uma PAR **a nível de bucket** (raiz do bucket, não de um objeto
  específico) com:
  - permissão de **leitura e escrita** no mínimo (necessário para upload e para
    `verify_upload`/`restore`);
  - **"Enable Object Listing" habilitado** — sem isso `latest` não funciona,
    porque o GET de listagem na raiz da PAR é rejeitado pela OCI (confirmado
    testando contra um bucket real: com a opção ligada, `GET <PAR>/` retorna
    `{"objects":[...]}` normalmente);
  - permissão de **delete**, se quiser retenção remota automática (sem isso o
    upload/verify/restore funcionam normalmente, mas a retenção só loga um
    aviso e não apaga nada — não é fatal).

  O nome do arquivo é anexado à URL da PAR na hora do upload/download.
  - **Listagem sem paginação**: a checagem de `latest`/retenção lê só a
    primeira página de resultados da OCI. Mantendo um prefixo/bucket por
    projeto e uma retenção razoável, isso não chega a ser um problema na
    prática, mas buckets com um volume muito grande de objetos podem não
    aparecer inteiros numa única listagem.
- **`local`** — copia o dump (e o `.sha256`) para outro caminho dentro do
  próprio container, via `cp`. Serve pra um segundo disco, um mount de NAS, ou
  qualquer outro ponto de montagem que não seja o `BACKUP_DIR` de staging
  (que já tem sua própria retenção via `retention.local_days`, independente
  disso). O `path` precisa estar montado como volume no `docker-compose.yml`.
  Suporta upload, `verify_upload`, `latest`, `remote` e retenção automática
  (mesmo critério de idade por nome de arquivo usado no staging).
- **Outros métodos**: qualquer backend que o `rclone` suporte (Backblaze B2,
  Google Cloud Storage, Azure Blob, SFTP, WebDAV, disco local...) já funciona
  bastando declarar um novo `remotes:` com `type` compatível e usar
  `type: s3` só quando for de fato S3; para os outros protocolos do rclone,
  adicione o tipo correspondente no `remotes:` e estenda `render-rclone-conf.sh`
  (hoje ele só escreve o formato de um remote `s3`, mas o `backup.sh`/`restore.sh`
  já tratam `s3`/`r2` de forma genérica via rclone).

## Notificações

Cada banco pode ter uma lista de canais em `notifications:` (própria, ou
herdada de `defaults.notifications` — sempre tudo-ou-nada, nunca um merge
campo a campo). Cada canal escolhe em quais eventos dispara via `on:`:

- **`start`** — logo antes de começar o `pg_dump`.
- **`success`** — todos os destinos configurados receberam o backup.
- **`warning`** — **falha parcial**: pelo menos um destino recebeu o backup,
  mas pelo menos um outro falhou (testado de verdade: com 1 de 2 destinos
  fora do ar, o evento disparado foi `warning`, não `failure` — o backup
  existe em algum lugar, só não replicou por completo). Retenção remota que
  falha também dispara `warning`. O `backup.sh` ainda sai com exit code `1`
  nesse caso, pra ferramentas de monitoramento de cron perceberem que ficou
  pendência, mesmo não sendo uma perda total.
- **`failure`** — falha total: `pg_dump`/checagem estrutural/restore de teste
  falhou, ou **todos** os destinos falharam no upload.

**Sem `on:` explícito, o canal só dispara em `failure`** — silencioso no
resto, de propósito, pra não gerar notificação toda noite em quem tem muitos
bancos configurados.

### Canais disponíveis

- **`webhook`** — igual ao mecanismo original: `curl -X POST` com um JSON no
  corpo. `format: slack` (`{"text":...}`) funciona também pra qualquer
  endpoint compatível (Mattermost, Rocket.Chat, etc.); `format: discord` usa
  `{"content":...}`, que é o que a API de webhook do Discord espera.
- **`telegram`** — via [Bot API](https://core.telegram.org/bots/api), sem
  biblioteca nenhuma, só `curl --data-urlencode` pro endpoint
  `sendMessage`. Crie um bot com o [@BotFather](https://t.me/BotFather) pra
  pegar o `bot_token`, e mande uma mensagem qualquer pro bot (ou adicione
  num grupo) pra descobrir o `chat_id` — testado contra a API real da
  Telegram (a chamada chega formada corretamente; só falta um token/chat_id
  válidos de verdade pra completar o envio).
- **`email`** — via [`msmtp`](https://marlam.de/msmtp/), um cliente SMTP
  simples (sem precisar de um MTA completo tipo Postfix). Testado de ponta a
  ponta contra um servidor SMTP local (mensagem chega com `From`/`To`/
  `Subject`/corpo corretos) e a negociação TLS/STARTTLS foi confirmada
  batendo certo contra um servidor real (a senha nunca aparece em `ps aux` —
  é passada via `--passwordeval` lendo de uma variável de ambiente do
  próprio processo do `msmtp`, nunca como argumento de linha de comando).
  Sempre usa STARTTLS na porta configurada (`587` por padrão); não há opção
  hoje pra TLS implícito (porta 465).
- **`ntfy`** — push notification simples via [ntfy.sh](https://ntfy.sh/) (ou
  uma instância própria autohospedada), sem conta nem app necessário — só
  `curl -d "mensagem" https://ntfy.sh/seu-topico`. Testado de ponta a ponta
  contra o serviço público real. **O nome do tópico é o único "segredo"**:
  qualquer pessoa que souber o nome consegue ler as mensagens (a menos que
  você hospede sua própria instância com autenticação) — escolha um nome
  longo e não-óbvio, tipo `pg-backup-<algo-aleatorio>`.

## Reprocessar um backup manualmente

Se o dump deu certo mas o **upload falhou** em algum destino (rede,
credencial expirada, bucket fora do ar...), o arquivo local já existe em
`/backups` — não precisa esperar o próximo horário do cron nem gerar um dump
novo pra tentar de novo:

```bash
# reenvia o backup mais recente desse banco pra TODOS os destinos configurados
docker compose exec pg-backup /app/scripts/resend.sh app-critico latest

# reenvia só pro destino que falhou (os que já deram certo não precisam)
docker compose exec pg-backup /app/scripts/resend.sh app-critico latest oci-arquivo-frio

# ou aponta um arquivo específico em vez de "latest"
docker compose exec pg-backup /app/scripts/resend.sh app-critico app-critico_2026-08-30_02-15-00.dump oci-arquivo-frio
```

O `resend.sh` roda a mesma lógica de upload/`verify_upload`/`checksum_after_upload`
do `backup.sh`, só que pulando `pg_dump` inteiro — e dispara notificação
(`success`/`warning`/`failure`) igual a um backup normal. É exatamente o que
a mensagem de `warning` de um backup parcial já sugere fazer.

## Verificações feitas em todo backup

1. **Checagem estrutural** — `pg_restore --list` no arquivo recém-gerado,
   antes de subir para qualquer destino. Pega dump truncado/corrompido cedo,
   sem gastar upload.
2. **Checksum** — SHA-256 do dump, salvo como `<arquivo>.sha256` e enviado
   junto a cada destino.
3. **Verificação de upload** — após enviar, confere se o tamanho do objeto no
   destino bate com o tamanho local (via `rclone lsjson` ou `HEAD` na PAR).
   Isso pega upload truncado/incompleto, mas é só tamanho — não é o mesmo que
   conferir o conteúdo byte a byte.
4. **Checksum pós-upload (opt-in, `verify.checksum_after_upload: true`)** —
   confere um MD5 real do que ficou no destino contra o MD5 local, **sem
   baixar o arquivo de novo**: em `s3`/`r2` lê o MD5 do header `ETag` que o
   próprio backend já retorna num `HEAD` (via `rclone hashsum md5`); na OCI
   lê o header `content-md5` (também via `HEAD` na PAR). Confirmado na prática
   contra MinIO (S3) e um bucket OCI real: ambos retornam o hash sem
   transferir o corpo do objeto. Único requisito pro `ETag` valer como MD5:
   upload feito numa parte só (sem multipart) — que é sempre o caso pra dumps
   de banco de dados dentro de tamanhos normais; se o backend não conseguir
   informar o hash, o script só avisa e segue (não é fatal). Pra destino
   `local` a comparação é direta (dois `md5sum` no mesmo disco). Desligado por
   padrão porque, mesmo sem custo de rede, ainda é uma chamada HTTP a mais por
   destino a cada backup.
5. **Restore de teste (opt-in, `verify.test_restore: true`)** — cria um banco
   descartável no mesmo servidor (`createdb`), roda `pg_restore` nele de
   verdade e apaga em seguida (`dropdb`). Exige privilégio `CREATEDB` no
   usuário configurado; fica desligado por padrão porque é mais caro e usa
   recursos do servidor de origem.

## Uso

### 1. Configurar

```bash
cp config/databases.example.yml config/databases.yml
cp .env.example .env
# edite os dois arquivos com seus bancos/segredos reais
```

Ajuste `docker-compose.yml` para entrar nas networks Docker corretas (por
padrão assume uma network externa compartilhada chamada `padrao`, igual ao
padrão já usado nos composes de projeto).

### 2. Subir o serviço

```bash
docker compose up -d --build
docker compose logs -f
```

No boot, o log mostra a tabela de bancos carregados e o crontab gerado.

### 3. Rodar um backup manualmente (sem esperar o cron)

```bash
docker compose exec pg-backup /app/scripts/backup.sh app-critico
```

### 4. Restaurar

```bash
# do backup local mais recente já baixado
docker compose exec pg-backup /app/scripts/restore.sh app-critico local /backups/app-critico_2026-08-30_02-15-00.dump

# baixando o mais recente de um destino específico (app-critico tem 4 configurados)
docker compose exec pg-backup /app/scripts/restore.sh app-critico latest r2-secundario

# baixando um arquivo específico de um destino
docker compose exec pg-backup /app/scripts/restore.sh app-critico remote r2-secundario app-critico_2026-08-30_02-15-00.dump
```

Sempre pede confirmação interativa antes de rodar `pg_restore --clean`.

### 5. Verificar um backup específico

```bash
docker compose exec pg-backup /app/scripts/verify.sh app-critico --file /backups/app-critico_2026-08-30_02-15-00.dump --test-restore
```

### 6. Listar bancos configurados

```bash
docker compose exec pg-backup /app/scripts/list.sh
```

### 7. Aplicar mudanças de configuração

O `rclone.conf` e o crontab só são gerados **uma vez**, no boot do container
(`entrypoint.sh`). Editar `config/databases.yml` ou `.env` no host não muda
nada sozinho — o comando certo depende de qual arquivo mudou (testado e
confirmado com containers reais):

| O que mudou | Comando | Por quê |
|---|---|---|
| `config/databases.yml` (bancos, schedule, retenção, destinos) | `docker compose restart pg-backup` | É um bind mount: o Compose não enxerga isso como mudança de configuração, então `up -d` sozinho **não faz nada** (container continua rodando com o crontab antigo). `restart` reinicia o processo e roda o `entrypoint.sh` de novo, que relê o YAML atual. |
| `.env` (senhas, chaves, URLs de webhook/PAR) | `docker compose up -d` | O Compose detecta a mudança nas variáveis de ambiente resolvidas e recria o container sozinho (não precisa de `restart` nem `--build`). |
| `Dockerfile` ou qualquer arquivo em `scripts/` | `docker compose up -d --build` | Precisa reconstruir a imagem antes de recriar o container. |
| Só quer garantir que pegou tudo, sem pensar em qual regra vale | `docker compose up -d --force-recreate` (ou `--build` junto, se mexeu em código) | Recria do zero sempre, custa só alguns segundos a mais. |

Depois de qualquer uma dessas, confira com `docker compose exec pg-backup /app/scripts/list.sh` e `docker compose exec pg-backup crontab -l` se o crontab reflete o que você esperava.

## Adicionando um novo projeto

Basta um novo item em `databases:` no YAML (host, credenciais via `.env`,
schedule, destinos) — sem build de imagem nova, sem editar compose de projeto
nenhum. Depois, aplique a mudança como descrito acima (`docker compose
restart pg-backup` cobre o caso comum de só ter mexido no YAML). Se o projeto
estiver numa network Docker diferente da já conectada, adicione essa network
em `docker-compose.yml` e rode `docker compose up -d` (mudança no próprio
arquivo do compose, então o Compose recria o container sozinho).

## Notas de segurança

- `.env` e `config/databases.yml` reais nunca são versionados (`.gitignore`).
- Os campos sensíveis no YAML são sempre *nomes* de variável, nunca o valor.
- A PAR da OCI já É o segredo — trate a URL como uma senha.
- O crontab gerado (`/var/spool/cron/crontabs/root` dentro do container)
  também acaba guardando os valores resolvidos de `.env` em texto puro — é
  necessário pro cron conseguir rodar os jobs sozinho (ver seção "Como
  funciona"). O arquivo fica `0600`, só root, mesmo nível de proteção que o
  resto do container já tinha (`.env` montado, `rclone.conf` etc.) — não é
  uma exposição nova, só vale saber que esse arquivo também é sensível.
