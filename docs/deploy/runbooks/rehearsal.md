# Runbook — Ensaio do cutover e do deploy quente (VM descartável)

Valida TUDO fora de produção: restore do backup S3, cutover, deploy quente com
curl-loop, rollback. Destruir a VM ao final.

## 1. VM

`hcloud server create --name ndesk-ensaio --type cpx41 --image ubuntu-24.04 --ssh-key <sua-chave>`
No host novo: `curl -fsSL https://get.docker.com | sh` (confere `docker --version` ≥ 29).

## 2. Replicar a config de produção

Copiar de prod para a VM, mesma árvore:

- Antes de copiar, conferir que o `.env` de prod contém as 10 variáveis que o
  preflight do `deploy.sh` exige (`ZAMMAD_*_RESOURCES_LIMITS_MEMORY` ×9 +
  `ELASTICSEARCH_JAVA_OPTS`) — se faltar alguma, ajustar em PROD primeiro e então
  copiar (senão o deploy falha no ensaio com a lista das faltantes).
- `/opt/zammad/{docker-compose.yml,docker-compose.override.yml,scenarios,.env}`
- `/opt/ndesk/deploy/` (ou rsync do checkout local: `rsync -av deploy/ root@<vm>:/opt/ndesk/deploy/`)

**Ajustes OBRIGATÓRIOS no `.env` da VM:**

- `CLOUDFLARE_TUNNEL_REPLICAS=0` e `CLOUDFLARE_TUNNEL_TOKEN=dummy` — o token de
  produção NUNCA roda fora de prod (o tunnel roubaria tráfego real do helpdesk).
- `SMOKE_URL=http://localhost:8080/` (não há tunnel na VM).

## 3. Restore do backup de produção

- Baixar o par mais recente do S3 (mesmo timestamp):
  `aws s3 ls s3://newbyte-backups/ndesk/ | sort | tail -5`
  `aws s3 cp s3://newbyte-backups/ndesk/<ts>_zammad_db.psql.gz .`
  `aws s3 cp s3://newbyte-backups/ndesk/<ts>_zammad_files.tar.gz .`
- Criar os volumes e semear o diretório de restore:

  ```bash
  for v in postgresql-data redis-data elasticsearch-data zammad-storage zammad-backup; do
    docker volume create "zammad_${v}"
  done
  docker run --rm -v zammad_zammad-backup:/b -v "$PWD":/src alpine \
    sh -c 'mkdir -p /b/restore && cp /src/*_zammad_*.gz /b/restore/'
  ```

- Subir o stack compose igual produção (o serviço `zammad-backup` detecta
  `restore/` e restaura DB+storage sozinho; os demais serviços ESPERAM o restore):
  `cd /opt/zammad && docker compose -f docker-compose.yml -f scenarios/apply-resource-limits.yml up -d`
  (sem o scenario do tunnel na VM). Acompanhar: `docker compose logs -f zammad-backup`
  até "Restore completed", depois esperar o app subir e responder em `:8080`.

## 4. Ensaiar o cutover

Executar `cutover.md` passos 1–6 na VM (a TAG é a do VERSION restaurado; smoke em
`http://localhost:8080/`; ignorar o passo do tunnel/FQDN público).

## 5. Ensaiar o deploy quente (o teste que importa)

- Curl-loop num terminal separado (da SUA máquina, contra a VM):

  ```bash
  while :; do
    printf '%s %s\n' "$(date -u +%T)" \
      "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://<vm>:8080/)"
    sleep 1
  done | tee /tmp/curl-loop.log
  ```

- Disparar: `bash /opt/ndesk/deploy/deploy.sh <TAG>` (a mesma tag serve — o
  rolling completo é exercitado do mesmo jeito).
- **Critério de aceite:** nenhum código fora de 2xx/3xx no log durante o rolling.
- **Memória:** durante o overlap dos dois railsservers, rodar `docker stats
  --no-stream` na VM e registrar o pico. Se houver OOM/kill, ajustar limites antes
  do cutover real.
- Ensaiar também o caminho de manutenção: `bash /opt/ndesk/deploy/deploy.sh <TAG> --maintenance`
  (deve parar o app, "migrar" no-op e voltar).
- Ensaiar também o **rollback de deploy**: `bash /opt/ndesk/deploy/deploy.sh <tag-anterior>`
  e confirmar que converge. Em produção, um rollback por dispatch roda o deploy.sh e o
  stack.yml ATUAIS contra uma imagem ANTIGA — essa combinação precisa ser exercitada aqui.

## 6. Ensaiar o rollback do cutover

Executar a seção "Rollback do cutover" do `cutover.md` na VM e confirmar que o
compose volta a servir em `:8080`. (Na VM, omitir `-f scenarios/add-cloudflare-tunnel.yml`
do `compose up`, como no §3 — com o token dummy o cloudflared entra em crash-loop.)

## 7. Encerrar

- Registrar achados + `/tmp/curl-loop.log` em `docs/deploy/evidence/` (commit).
- `hcloud server delete ndesk-ensaio`
