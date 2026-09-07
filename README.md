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
- O dump de cada banco fica em `BACKUP_DIR/<id>/` — uma subpasta por banco,
  nunca misturado com o de outro (`./backups/app-simples/`,
  `./backups/app-critico/`, ...). `restore.sh`/`resend.sh` já resolvem nomes
  de arquivo relativos dentro da subpasta certa sozinhos.
- Toda a configuração fica em **um único arquivo YAML**
  (`config/databases.yml`), e **cada banco é 100% independente** — sem seção
  compartilhada tipo "defaults", sem remote nomeado reutilizado entre bancos.
  Todo valor, inclusive senha/chave de API/token, fica escrito direto no
  campo correspondente, por banco — **não existe `.env`**: é o próprio
  `config/databases.yml` que fica fora do git (`.gitignore`) e guarda os
  segredos.
- O agendamento é feito com `cron` de verdade dentro do container: no start,
  o `entrypoint.sh` lê `databases.yml` e gera um crontab com uma linha por
  banco habilitado, cada uma rodando `backup.sh <id>`. **Bancos com o mesmo
  horário rodam de verdade em paralelo** — confirmado observando dois
  `pg_dump` simultâneos disparados pelo próprio cron, não só em teoria. Como
  toda a configuração (inclusive segredos) mora no arquivo YAML — não em
  variável de ambiente —, o job disparado pelo cron lê exatamente os mesmos
  dados que uma execução manual via `docker compose exec` leria, sem precisar
  de nenhum truque de propagação de ambiente.
- Upload S3/R2 é feito via `rclone`, mas **sem `rclone.conf` compartilhado**:
  cada destino monta sua própria "remote on the fly" do rclone
  (`:s3,provider=...,access_key_id="...",secret_access_key="...":bucket/`)
  na hora da chamada, usando só as credenciais daquele destino específico —
  testado contra um MinIO real (upload, download, listagem, hashsum,
  delete). PARs da OCI são feitas via `curl` puro (`PUT`/`GET`/`HEAD`/`DELETE`
  direto na URL).
- Notificações são configuráveis por evento (início, sucesso, aviso, falha) e
  por canal (webhook Slack/Discord/genérico, Telegram, e-mail via SMTP, ntfy)
  — ver seção "Notificações" abaixo.
- Todo `backup.sh`/`resend.sh`/`restore.sh`/`verify.sh` grava sua própria saída
  em `LOG_DIR/<id>.log` — via cron **ou** rodado na mão, sempre no mesmo
  arquivo, persistido fora do container e rotacionado automaticamente. Ver
  seção "Logs" abaixo.

## Estrutura

```
config/
  databases.example.yml   # copie para databases.yml e edite
scripts/
  entrypoint.sh            # gera o crontab e sobe o cron em foreground
  backup.sh <id>            # dump -> checagens -> upload -> retenção
  resend.sh <id> ...         # reenvia um dump JÁ EXISTENTE local, sem rodar pg_dump de novo
  restore.sh <id> ...         # baixa e restaura um backup
  verify.sh <id> ...           # checagem avulsa de um arquivo já baixado
  list.sh                       # lista os bancos configurados
  logs.sh <id> ...               # consulta o log persistido/rotacionado de um banco
  lib/
    common.sh                   # funções compartilhadas (inclui start_logging)
    render-crontab.sh            # gera o crontab a partir de `databases:`
    render-logrotate.sh           # gera /etc/logrotate.d/pg-backup a partir de LOG_DIR
Dockerfile
docker-compose.yml
```

## Configuração (`databases.yml`)

`config/databases.example.yml` (reproduzido aqui, sempre sincronizado com o
arquivo real) traz **3 bancos de exemplo**, cada um variando um conjunto
diferente de parâmetros pra cobrir, entre os três, quase toda a superfície de
configuração possível. Cada banco é uma entrada completa e autocontida —
nada de herdar de uma seção comum:

- **`app-simples`** — o mínimo indispensável: só os campos realmente
  obrigatórios, o resto usa o valor padrão do próprio script. Um único
  destino na nuvem, **sem** nenhum destino `local` além do staging temporário
  que sempre existe.
- **`app-critico`** — todo campo explícito (schedule, retenção, os 5 flags de
  `verify`, incluindo os dois opt-in) e backup replicado nos **4 tipos de
  destino ao mesmo tempo** (S3 + R2 + OCI PAR + disco local), cada um com sua
  própria credencial embutida — nenhum "remote" compartilhado entre eles.
  Notificação em 3 canais diferentes (Telegram + e-mail + Discord), cada um
  com seu próprio conjunto de eventos.
- **`app-legado`** — `format: plain` (em vez do `custom` default),
  `enabled: false` (fora do crontab automático, mas ainda rodável na mão) e
  um único destino, do tipo `local` — o espelho do `app-simples` (que não
  tinha nenhum `local`). Notificação mínima: só um `ntfy` em `on: [failure]`.

```yaml
databases:
  - id: app-simples
    schedule: "0 3 * * *"
    connection:
      host: app-simples-postgres
      database: app_simples
      password: "TROQUE-ESTA-SENHA"
    destinations:
      - name: r2-principal
        type: r2
        provider: Cloudflare
        endpoint: "https://SEU_ACCOUNT_ID.r2.cloudflarestorage.com"
        access_key_id: "SUA_R2_ACCESS_KEY_ID"
        secret_access_key: "SUA_R2_SECRET_ACCESS_KEY"
        bucket: app-simples-backups
        prefix: app-simples/
    notifications:
      - type: webhook
        format: slack
        url: "https://hooks.slack.com/services/SEU/WEBHOOK/AQUI"
        on: [failure]

  - id: app-critico
    enabled: true
    schedule: "15 2 * * *"
    format: custom
    connection:
      host: app-critico-postgres
      port: 5432
      user: postgres
      database: app_critico
      password: "TROQUE-ESTA-SENHA-TAMBEM"
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
        provider: AWS
        region: us-east-1
        access_key_id: "SUA_AWS_ACCESS_KEY_ID"
        secret_access_key: "SUA_AWS_SECRET_ACCESS_KEY"
        bucket: app-critico-backups-primario
        prefix: app-critico/
      - name: r2-secundario
        type: r2
        provider: Cloudflare
        endpoint: "https://SEU_ACCOUNT_ID.r2.cloudflarestorage.com"
        access_key_id: "SUA_R2_ACCESS_KEY_ID"
        secret_access_key: "SUA_R2_SECRET_ACCESS_KEY"
        bucket: app-critico-backups-secundario
        prefix: app-critico/
      - name: oci-arquivo-frio
        type: oci_par
        par_url: "https://objectstorage.SUA-REGIAO.oraclecloud.com/p/SEU-TOKEN-DA-PAR/n/SEU-NAMESPACE/b/SEU-BUCKET/o"
      - name: disco-secundario
        type: local
        path: /mnt/backup-secundario/app-critico/
    notifications:
      - type: telegram
        name: telegram-oncall
        bot_token: "123456789:AAAbotTokenDeExemploAqui"
        chat_id: "-1001234567890"
        on: [start, success, warning, failure]
      - type: email
        smtp_host: smtp.seuservidor.com
        smtp_port: 587
        smtp_user: "backups@seudominio.com"
        smtp_password: "SUA_SENHA_SMTP"
        from: "backups@seudominio.com"
        to: "oncall@seudominio.com"
        on: [failure, warning]
      - type: webhook
        format: discord
        url: "https://discord.com/api/webhooks/SEU/WEBHOOK/AQUI"
        on: [failure]

  - id: app-legado
    enabled: false
    schedule: "0 4 * * *"
    format: plain
    connection:
      host: app-legado-postgres
      database: app_legado
      password: "TROQUE-ESTA-SENHA-TAMBEM-2"
    destinations:
      - name: disco-secundario
        type: local
        path: /mnt/backup-secundario/app-legado/
    notifications:
      - type: ntfy
        url: "https://ntfy.sh/SEU-TOPICO-PRIVADO-E-DIFICIL-DE-ADIVINHAR"
        priority: default
        on: [failure]
```

Cada `id` em `databases:` é a unidade atômica de agendamento/retenção/destino
— exatamente o "parametrizado banco a banco" pedido: dois bancos no mesmo
servidor Postgres viram duas entradas independentes, cada uma com sua própria
cópia de tudo.

### Referência completa de parâmetros

Todo campo abaixo é lido **só** do próprio banco — não existe herança de
nenhuma outra parte do arquivo. "Default" na tabela é um valor fixo do
próprio script (mesmo pra todo banco que omitir o campo), não configuração
compartilhada.

**`databases[]`** (raiz do YAML — um item por banco, totalmente independente)

| Campo | Tipo | Obrigatório | Default | Descrição |
|---|---|---|---|---|
| `id` | string | Sim | — | Identificador único; vira prefixo do nome do arquivo (`<id>_AAAA-MM-DD_HH-MM-SS.ext`) e é o argumento passado para `backup.sh`/`restore.sh`/`resend.sh`/`verify.sh`. |
| `enabled` | boolean | Não | `true` | `false` tira o banco do crontab gerado (ainda dá pra rodar `backup.sh <id>` manualmente). |
| `schedule` | string (cron, 5 campos) | Não | `0 3 * * *` | Horário do backup. **Bancos com o mesmo `schedule` disparam em paralelo** (o `cron` não enfileira) — se tiver muitos bancos, considere escalonar os horários (`03:00`, `03:10`, `03:20`...) pra não competir por CPU/rede no mesmo instante. |
| `format` | `custom` \| `plain` | Não | `custom` | Formato do `pg_dump` (`-Fc`/`-Fp`). Com `plain` a checagem estrutural é pulada (`pg_restore --list` não existe pra SQL puro). **`directory` (`-Fd`) não é suportado ainda** — testado e confirmado quebrado: gera múltiplos arquivos numa pasta, e checksum/upload/verificação/retenção assumem hoje "um dump = um arquivo só" em todo o pipeline; `backup.sh` recusa esse valor de propósito, com erro claro. |
| `connection` | objeto | Sim | — | Ver tabela abaixo. |
| `retention.local_days` | inteiro | Não | `7` | Dias que o dump fica no `BACKUP_DIR` de staging (`/backups/<id>/`) antes de ser apagado. |
| `retention.remote_days` | inteiro | Não | `30` | Dias até apagar de **cada** destino em `destinations:` — vale para `s3`, `r2`, `oci_par` (se a PAR permitir delete) e `local`. |
| `verify.structural_check` | boolean | Não | `true` | `pg_restore --list` no dump logo após gerá-lo, antes do upload. |
| `verify.checksum` | boolean | Não | `true` | Gera `<arquivo>.sha256` e envia junto a cada destino. |
| `verify.verify_upload` | boolean | Não | `true` | Confere o tamanho do arquivo no destino logo após o envio. |
| `verify.checksum_after_upload` | boolean | Não | `false` | Confere um MD5 real do destino contra o local, sem re-baixar (lê `ETag`/`content-md5` via `HEAD`). Ver "Verificações feitas em todo backup". |
| `verify.test_restore` | boolean | Não | `false` | Restore completo num banco descartável no mesmo servidor (`createdb`/`pg_restore`/`dropdb`). Exige `CREATEDB` no `connection.user`; mais caro, por isso opt-in. |
| `destinations` | array (≥1) | Sim | — | Ver tabela abaixo. Sem nenhum item, o backup falha de propósito. |
| `notifications` | array | Não | (nenhuma notificação) | Ver seção "Notificações" abaixo. |

**`databases[].connection`**

| Campo | Tipo | Obrigatório | Default | Descrição |
|---|---|---|---|---|
| `host` | string | Sim | — | Hostname resolvível na network Docker (nome do container/serviço do Postgres alvo). |
| `port` | inteiro | Não | `5432` | Porta do Postgres. |
| `user` | string | Não | `postgres` | Usuário do `pg_dump`/`pg_restore`; precisa de `CREATEDB` se `verify.test_restore: true`. |
| `database` | string | Sim | — | Nome do banco a ser copiado. |
| `password` | string | Sim | — | Senha desse usuário, em texto puro (é por isso que `config/databases.yml` real fica fora do git). |

**`databases[].destinations[]`** — campos comuns a todo item:

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `name` | string | Sim | Identifica o destino em `restore.sh`/`resend.sh ... latest/remote <name> ...`, nos logs e no `list.sh`. |
| `type` | `s3` \| `r2` \| `oci_par` \| `local` | Sim | Define quais campos abaixo se aplicam. |

Campos extras por `type` — `s3`/`r2` **não referenciam nenhum remote
compartilhado**: cada destino carrega sua própria credencial, montada numa
["on the fly remote"](https://rclone.org/docs/#connection-strings) do rclone
na hora do upload/download:

| `type` | Campo | Obrigatório | Descrição |
|---|---|---|---|
| `s3` / `r2` | `provider` | Não | Dica pro rclone (`AWS`, `Cloudflare`, `Minio`, `Other`...). |
| `s3` / `r2` | `region` | Não | Região S3 (ex.: `us-east-1`); ignorado por backends sem conceito de região (R2, por ex.). |
| `s3` / `r2` | `endpoint` | Depende | URL do endpoint S3-compatível. Obrigatório pra qualquer backend que não seja AWS S3 "de verdade" (R2, MinIO...). |
| `s3` / `r2` | `access_key_id` | Sim | Access Key ID, em texto puro. |
| `s3` / `r2` | `secret_access_key` | Sim | Secret Access Key, em texto puro. |
| `s3` / `r2` | `bucket` | Sim | Nome do bucket. |
| `s3` / `r2` | `prefix` | Não | Prefixo/"pasta" dentro do bucket (ex.: `meu-projeto/`). |
| `oci_par` | `par_url` | Sim | URL completa da PAR (nível de bucket — ver requisitos de permissão na seção de tipos de destino, abaixo). |
| `local` | `path` | Sim | Caminho absoluto **dentro do container** onde copiar o dump; precisa estar montado como volume no `docker-compose.yml`. |

**`databases[].notifications[]`** — campos comuns a todo item:

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `type` | `webhook` \| `telegram` \| `email` \| `ntfy` | Sim | Define quais campos abaixo se aplicam. |
| `name` | string | Não | Só pra identificar o canal nos logs; default é o próprio `type`. |
| `on` | array de `start`\|`success`\|`warning`\|`failure` | Não | Em quais eventos esse canal dispara. **Default: `[failure]`** — se quiser confirmação de sucesso ou do início do backup, precisa adicionar explicitamente. |

Campos extras por `type` (ver seção "Notificações" para detalhes de cada canal):

| `type` | Campo | Obrigatório | Descrição |
|---|---|---|---|
| `webhook` | `url` | Sim | URL do webhook, em texto puro. |
| `webhook` | `format` | Não | `slack` (`{"text":...}`, default) \| `discord` (`{"content":...}`) \| `generic` (mesmo formato do slack). |
| `telegram` | `bot_token` | Sim | Token do bot (via [@BotFather](https://t.me/BotFather)), em texto puro. |
| `telegram` | `chat_id` | Sim | `chat_id` de destino. |
| `email` | `smtp_host` | Sim | Host SMTP. |
| `email` | `smtp_port` | Não | Porta; default `587` (STARTTLS). |
| `email` | `smtp_user` | Sim | Usuário SMTP. |
| `email` | `smtp_password` | Sim | Senha SMTP, em texto puro. |
| `email` | `from` | Sim | Remetente (`From:`). |
| `email` | `to` | Sim | Destinatário(s) — um ou vários, separados por vírgula (`"a@x.com, b@x.com"`). Testado ponta a ponta com 2 destinatários: o servidor recebeu dois `RCPT TO` distintos, não uma string quebrada. |
| `ntfy` | `url` | Sim | URL completa do tópico (ex.: `https://ntfy.sh/meu-topico`). |
| `ntfy` | `priority` | Não | `min`\|`low`\|`default`\|`high`\|`urgent`. |

**Fora do YAML** (variáveis de ambiente lidas direto pelo container, via compose `environment:` — nada sensível fica aqui):

| Variável | Default | Descrição |
|---|---|---|
| `CONFIG_FILE` | `/app/config/databases.yml` | Caminho do YAML dentro do container. |
| `BACKUP_DIR` | `/backups` | Diretório de staging dos dumps. |
| `LOG_DIR` | `/var/log/pg-backup` | Onde `backup.sh`/`resend.sh`/`restore.sh`/`verify.sh` gravam `<id>.log` (ver seção "Logs"). |
| `TZ` | `America/Sao_Paulo` | Timezone usado pelo `cron` para interpretar os `schedule`. |

### Tipos de destino suportados hoje

- **`s3`** / **`r2`** — via `rclone`, para qualquer backend S3-compatível
  (AWS S3, Cloudflare R2, MinIO, Backblaze B2 via API S3 etc.), credenciais
  embutidas por destino. Suporta upload, download, listagem (`latest`) e
  retenção remota automática (`rclone delete --min-age`) — testado de ponta a
  ponta contra um MinIO real, incluindo o mecanismo de "remote on the fly"
  (sem `rclone.conf`, sem remote nomeado): confirmei via dump de tráfego HTTP
  que `rclone hashsum` usa `HEAD`, não baixa o arquivo, e que `mkdir`/`copy`/
  `lsf`/`delete` funcionam normalmente só com a string de conexão montada na
  hora.
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

## Notificações

Cada banco pode ter uma lista de canais em `notifications:` — sem herança de
lugar nenhum; um banco sem `notifications:` simplesmente não notifica nada.
Cada canal escolhe em quais eventos dispara via `on:`:

- **`start`** — logo antes de começar o `pg_dump`.
- **`success`** — todos os destinos configurados receberam o backup.
- **`warning`** — **falha parcial**: pelo menos um destino recebeu o backup,
  mas pelo menos um outro falhou (testado de verdade: com 1 de 2 destinos
  fora do ar, o evento disparado foi `warning`, não `failure` — o backup
  existe em algum lugar, só não replicou por completo). Retenção remota que
  falha também dispara `warning`. O `backup.sh` ainda sai com exit code `1`
  nesse caso, pra ferramentas de monitoramento de cron perceberem que ficou
  pendência, mesmo não sendo uma perda total. A mensagem já sugere usar
  `resend.sh` pra tentar de novo sem gerar um dump novo — ver seção abaixo.
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

## Logs

Antes disso, o log de cada job do cron ficava só dentro da camada gravável do
container — sem volume, sumia toda vez que o container era recriado
(`docker compose down`/`up`, `--force-recreate`, `--build` trocando a
imagem), e uma execução manual via `docker compose exec` não deixava rastro
nenhum além do que apareceu na hora no terminal.

Agora `backup.sh`, `resend.sh`, `restore.sh` e `verify.sh` espelham *toda* a
própria saída — logs formatados, e também qualquer erro cru de `pg_dump`/
`rclone`/`curl` — em `LOG_DIR/<id>.log`, **seja a execução via cron ou
manual, sempre no mesmo arquivo**. Testado de ponta a ponta: uma execução
manual apareceu no arquivo persistido no host; um disparo real do cron,
também; os dois ficaram no mesmo arquivo, em ordem cronológica.

- **Persistência**: `LOG_DIR` (`/var/log/pg-backup` por padrão) é montado
  como volume no `docker-compose.yml` (`./logs:/var/log/pg-backup`) — sobrevive
  a qualquer recriação do container.
- **Rotação**: `logrotate` roda diariamente via cron (linha fixa gerada pelo
  `entrypoint.sh`, não depende de `databases:`), mantendo **14 dias** por
  banco, comprimidos a partir do segundo dia (`<id>.log`, `<id>.log.1`,
  `<id>.log.2.gz`, ..., `<id>.log.14.gz`). Testado forçando rotações reais
  (`logrotate --force`) — inclusive um detalhe que só apareceu testando: o
  `logrotate` recusa rotacionar um diretório "world-writable" (comum
  dependendo de como o host monta o volume) por segurança; a config gerada já
  declara `su root root` pra resolver isso, já que o container inteiro roda
  como root mesmo.
- **Consulta**: `scripts/logs.sh`, considera automaticamente os arquivos
  rotacionados (inclusive `.gz`):

  ```bash
  docker compose exec pg-backup /app/scripts/logs.sh                          # lista os arquivos existentes
  docker compose exec pg-backup /app/scripts/logs.sh app-critico               # últimas 50 linhas
  docker compose exec pg-backup /app/scripts/logs.sh app-critico --tail 200     # últimas N linhas
  docker compose exec pg-backup /app/scripts/logs.sh app-critico --follow        # acompanha em tempo real
  docker compose exec pg-backup /app/scripts/logs.sh app-critico --grep ERRO      # procura em TODO o histórico, .gz incluído
  docker compose exec pg-backup /app/scripts/logs.sh app-critico --all             # concatena tudo, do mais antigo pro mais novo
  ```

  Como o volume também fica no host, também dá pra usar qualquer ferramenta
  direto em `./logs/<id>.log*` sem precisar entrar no container.

## Reprocessar um backup manualmente

Se o dump deu certo mas o **upload falhou** em algum destino (rede,
credencial expirada, bucket fora do ar...), o arquivo local já existe em
`BACKUP_DIR/<id>/` — não precisa esperar o próximo horário do cron nem gerar
um dump novo pra tentar de novo:

```bash
# reenvia o backup mais recente desse banco pra TODOS os destinos configurados
docker compose exec pg-backup /app/scripts/resend.sh app-critico latest

# reenvia só pro destino que falhou (os que já deram certo não precisam)
docker compose exec pg-backup /app/scripts/resend.sh app-critico latest oci-arquivo-frio

# ou aponta um arquivo específico em vez de "latest" (nome resolve dentro de BACKUP_DIR/app-critico/)
docker compose exec pg-backup /app/scripts/resend.sh app-critico app-critico_2026-08-30_02-15-00.dump oci-arquivo-frio
```

O `resend.sh` roda a mesma lógica de upload/`verify_upload`/`checksum_after_upload`
do `backup.sh`, só que pulando `pg_dump` inteiro — e dispara notificação
(`success`/`warning`/`failure`) igual a um backup normal.

## Verificações feitas em todo backup

1. **Checagem estrutural** — `pg_restore --list` no arquivo recém-gerado,
   antes de subir para qualquer destino. Pega dump truncado/corrompido cedo,
   sem gastar upload. Se falhar, **o arquivo é apagado** (testado: uma falha
   de `pg_dump` — ex.: senha errada — não deixa mais um `.dump` vazio/quebrado
   em `BACKUP_DIR/<id>/`, que `restore.sh`/`resend.sh latest` poderiam pegar
   sem perceber que é lixo).
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
chmod 600 config/databases.yml
# edite com seus bancos/segredos reais
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
# do backup local mais recente já baixado (nome do arquivo resolve dentro de BACKUP_DIR/app-critico/)
docker compose exec pg-backup /app/scripts/restore.sh app-critico local app-critico_2026-08-30_02-15-00.dump

# baixando o mais recente de um destino específico (app-critico tem 4 configurados)
docker compose exec pg-backup /app/scripts/restore.sh app-critico latest r2-secundario

# baixando um arquivo específico de um destino
docker compose exec pg-backup /app/scripts/restore.sh app-critico remote r2-secundario app-critico_2026-08-30_02-15-00.dump
```

Sempre pede confirmação interativa antes de rodar `pg_restore --clean`.

### 5. Verificar um backup específico

```bash
docker compose exec pg-backup /app/scripts/verify.sh app-critico --file /backups/app-critico/app-critico_2026-08-30_02-15-00.dump --test-restore
```

### 6. Listar bancos configurados

```bash
docker compose exec pg-backup /app/scripts/list.sh
```

### 7. Aplicar mudanças de configuração

O crontab só é gerado **uma vez**, no boot do container (`entrypoint.sh`).
Editar `config/databases.yml` no host não muda nada sozinho — como é tudo um
único arquivo agora (sem `.env` separado), a regra é simples: **qualquer
mudança no YAML precisa de `docker compose restart pg-backup`**. É um bind
mount, então o Compose não enxerga isso como mudança de configuração — `up -d`
sozinho **não faz nada** (testado: mesmo container, crontab antigo continua
valendo até reiniciar).

| O que mudou | Comando |
|---|---|
| `config/databases.yml` (qualquer campo — bancos, schedule, credenciais, destinos) | `docker compose restart pg-backup` |
| `Dockerfile` ou qualquer arquivo em `scripts/` | `docker compose up -d --build` |

Depois de qualquer uma dessas, confira com `docker compose exec pg-backup /app/scripts/list.sh` e `docker compose exec pg-backup crontab -l` se o crontab reflete o que você esperava.

## Adicionando um novo projeto

Basta um novo item em `databases:` no YAML, completo (host, senha, schedule,
destinos com suas próprias credenciais) — sem build de imagem nova, sem
editar compose de projeto nenhum, sem mexer em nenhum outro banco já
configurado. Depois, `docker compose restart pg-backup`. Se o projeto estiver
numa network Docker diferente da já conectada, adicione essa network em
`docker-compose.yml` e rode `docker compose up -d` (mudança no próprio
arquivo do compose, então o Compose recria o container sozinho).

## Notas de segurança

- `config/databases.yml` real nunca é versionado (`.gitignore`) — é ele que
  guarda toda senha/chave/token em texto puro agora, então rode
  `chmod 600 config/databases.yml` no host.
- A PAR da OCI já É o segredo — trate a URL como uma senha.
- O crontab gerado (`/var/spool/cron/crontabs/root` dentro do container) **não**
  contém segredo nenhum — só `TZ`/`CONFIG_FILE`/`BACKUP_DIR` e o horário de
  cada banco. Os scripts leem senha/chaves direto do YAML em tempo de
  execução, então não há necessidade de propagar nada sensível pro ambiente
  do cron.
