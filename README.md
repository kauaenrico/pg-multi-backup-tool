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
  banco habilitado, cada uma rodando `backup.sh <id>`.
- Upload é feito via `rclone` (qualquer backend S3-compatível: S3, Cloudflare
  R2, MinIO, B2 via API S3 etc.) ou via `curl` puro para uma **Pre-Authenticated
  Request (PAR)** da OCI Object Storage.

## Estrutura

```
config/
  databases.example.yml   # copie para databases.yml e edite
scripts/
  entrypoint.sh            # gera rclone.conf + crontab e sobe o cron em foreground
  backup.sh <id>            # dump -> checagens -> upload -> retenção
  restore.sh <id> ...        # baixa e restaura um backup
  verify.sh <id> ...          # checagem avulsa de um arquivo já baixado
  list.sh                      # lista os bancos configurados
  lib/
    common.sh                   # funções compartilhadas
    render-rclone-conf.sh         # gera rclone.conf a partir de `remotes:`
    render-crontab.sh              # gera o crontab a partir de `databases:`
Dockerfile
docker-compose.yml
.env.example
```

## Configuração (`databases.yml`)

Veja `config/databases.example.yml` para um exemplo completo comentado.
Estrutura resumida:

```yaml
defaults:              # valores usados quando o banco não define os seus
  schedule: "0 3 * * *"
  format: custom        # custom | plain | directory
  retention:
    local_days: 7
    remote_days: 30
  verify:
    structural_check: true   # pg_restore --list logo após o dump
    checksum: true             # gera/envia .sha256
    verify_upload: true          # confere tamanho no destino após upload
    test_restore: false           # restore completo num banco descartável (opt-in)

remotes:                 # remotes rclone reutilizáveis (S3-compatíveis)
  - name: r2-principal
    type: s3
    provider: Cloudflare
    endpoint_env: R2_ENDPOINT
    access_key_id_env: R2_ACCESS_KEY_ID
    secret_access_key_env: R2_SECRET_ACCESS_KEY

databases:                # um item por banco/projeto
  - id: meu-projeto
    enabled: true
    connection:
      host: meu-projeto-postgres    # nome do container na network compartilhada
      port: 5432
      user: postgres
      password_env: MEU_PROJETO_PGPASSWORD
      database: meu_banco
    schedule: "0 3 * * *"            # opcional, senão usa defaults.schedule
    retention: { local_days: 7, remote_days: 30 }
    destinations:
      - name: r2-principal
        type: r2
        remote: r2-principal
        bucket: meu-bucket
        prefix: meu-projeto/
      - name: oci-frio
        type: oci_par
        par_url_env: MEU_PROJETO_OCI_PAR_URL
    webhook_url_env: MEU_PROJETO_WEBHOOK_URL   # opcional
```

Cada `id` em `databases:` é a unidade atômica de agendamento/retenção/destino
— exatamente o "parametrizado banco a banco" pedido: dois bancos no mesmo
servidor Postgres viram duas entradas independentes.

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
- **Outros métodos**: qualquer backend que o `rclone` suporte (Backblaze B2,
  Google Cloud Storage, Azure Blob, SFTP, WebDAV, disco local...) já funciona
  bastando declarar um novo `remotes:` com `type` compatível e usar
  `type: s3` só quando for de fato S3; para os outros protocolos do rclone,
  adicione o tipo correspondente no `remotes:` e estenda `render-rclone-conf.sh`
  (hoje ele só escreve o formato de um remote `s3`, mas o `backup.sh`/`restore.sh`
  já tratam `s3`/`r2` de forma genérica via rclone).

## Verificações feitas em todo backup

1. **Checagem estrutural** — `pg_restore --list` no arquivo recém-gerado,
   antes de subir para qualquer destino. Pega dump truncado/corrompido cedo,
   sem gastar upload.
2. **Checksum** — SHA-256 do dump, salvo como `<arquivo>.sha256` e enviado
   junto a cada destino.
3. **Verificação de upload** — após enviar, confere se o tamanho do objeto no
   destino bate com o tamanho local (via `rclone lsjson` ou `HEAD` na PAR).
4. **Restore de teste (opt-in, `verify.test_restore: true`)** — cria um banco
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
docker compose exec pg-backup /app/scripts/backup.sh meu-projeto
```

### 4. Restaurar

```bash
# do backup local mais recente já baixado
docker compose exec pg-backup /app/scripts/restore.sh meu-projeto local /backups/meu-projeto_2026-08-30_03-00-00.dump

# baixando o mais recente de um destino
docker compose exec pg-backup /app/scripts/restore.sh meu-projeto latest r2-principal

# baixando um arquivo específico de um destino
docker compose exec pg-backup /app/scripts/restore.sh meu-projeto remote r2-principal meu-projeto_2026-08-30_03-00-00.dump
```

Sempre pede confirmação interativa antes de rodar `pg_restore --clean`.

### 5. Verificar um backup específico

```bash
docker compose exec pg-backup /app/scripts/verify.sh meu-projeto --file /backups/meu-projeto_2026-08-30_03-00-00.dump --test-restore
```

### 6. Listar bancos configurados

```bash
docker compose exec pg-backup /app/scripts/list.sh
```

## Adicionando um novo projeto

Basta um novo item em `databases:` no YAML (host, credenciais via `.env`,
schedule, destinos) — sem build de imagem nova, sem editar compose de projeto
nenhum. Se o projeto estiver numa network Docker diferente da já conectada,
adicione essa network em `docker-compose.yml` e reinicie o serviço.

## Notas de segurança

- `.env` e `config/databases.yml` reais nunca são versionados (`.gitignore`).
- Os campos sensíveis no YAML são sempre *nomes* de variável, nunca o valor.
- A PAR da OCI já É o segredo — trate a URL como uma senha.
