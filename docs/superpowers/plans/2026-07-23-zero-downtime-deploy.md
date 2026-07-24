<!-- markdownlint-disable MD013 MD031 MD032 MD040 -->
# Deploy Quase-Zero-Downtime (Swarm single-node) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploys de Releases `nb.*` em horário comercial sem downtime perceptível, via Swarm single-node no `prod-ndesk` com rolling `start-first` e migração pré-troca.

**Architecture:** O host vira Swarm de nó único; o stack (arquivos versionados em `deploy/`) substitui o compose de `/opt/zammad`. O workflow passa a: pull → job one-shot de migração (stack antigo servindo) → `docker stack deploy` com healthcheck gating e rollback automático → cache clear + smoke. Spec: `docs/superpowers/specs/2026-07-23-zero-downtime-deploy-design.md`. ADR: `docs/deploy/adr/0001-swarm-single-node-para-deploy-quente.md`.

**Tech Stack:** Docker Swarm (Docker 29.3.0), GitHub Actions (`appleboy/scp-action`, `appleboy/ssh-action`), bash, zammad-docker-compose (referência), Cloudflare Tunnel.

## Global Constraints

- Produção **nunca** referencia `latest`: imagem sempre `technewbyte/ndesk:${RELEASE_TAG}`.
- Nomes/aliases de rede preservam os hostnames atuais: `zammad-railsserver`, `zammad-nginx`, `zammad-websocket`, `zammad-scheduler`, `zammad-postgresql`, `zammad-redis`, `zammad-memcached`, `zammad-elasticsearch` (o tunnel do Cloudflare e o entrypoint dependem deles).
- Volumes `external` com os nomes exatos existentes: `zammad_postgresql-data`, `zammad_redis-data`, `zammad_elasticsearch-data`, `zammad_zammad-storage`, `zammad_zammad-backup` (o cron `s3-backup.sh` do host referencia o último pelo nome).
- `/opt/zammad/.env` é a única fonte de config/segredos no host — nunca comitar valores; o stack só referencia variáveis.
- Nomes fixos: stack `ndesk`, rede overlay attachable `ndesk-net`, diretório de deploy no servidor `/opt/ndesk/deploy`.
- Serviços de app rodam `stop-first` **apenas** para `zammad-scheduler` e `zammad-backup`; `railsserver`/`nginx`/`websocket` são `start-first` com healthcheck.
- Docs/runbooks/commits em PT-BR, formato de commit `<type>: <descrição>` sem attribution.
- Branch de trabalho: `feat/zero-downtime-deploy` a partir de `newbyte-stable`; PR para `newbyte-stable` (o workflow vive lá).

---

### Task 1: Stack file do Swarm (`deploy/stack.yml`)

**Files:**
- Create: `deploy/stack.yml`

**Interfaces:**
- Consumes: variáveis do `/opt/zammad/.env` de produção (mesmos nomes do compose oficial) + `RELEASE_TAG` exportada pelo `deploy.sh`.
- Produces: stack `ndesk` com serviços `ndesk_zammad-*`, rede externa `ndesk-net`, volumes externos `zammad_*`. O Task 2 (`deploy.sh`) referencia este arquivo por caminho relativo (`stack.yml` no mesmo diretório) e os nomes de serviço `ndesk_zammad-railsserver` etc.

- [ ] **Step 1: Criar a branch de trabalho**

```bash
git checkout newbyte-stable && git checkout -b feat/zero-downtime-deploy
```

- [ ] **Step 2: Escrever `deploy/stack.yml`**

Conteúdo completo (espelha o env do compose oficial de produção + scenario de limits; healthchecks e update_config novos):

```yaml
# Stack Swarm do NDesk em produção (prod-ndesk).
# Deployado EXCLUSIVAMENTE pelo deploy.sh (docker stack config | docker stack deploy) —
# nunca à mão. A tag da Release entra via RELEASE_TAG (obrigatória; nunca 'latest' — ADR 0001).
# Config/segredos vêm de /opt/zammad/.env, sourced pelo deploy.sh antes da interpolação.
#
# Atenção: no rolling start-first convivem 2 railsservers por ~1 min — o pico transitório
# de memória (+1x limite do railsserver) foi validado no ensaio (runbook rehearsal.md).

x-app-env: &app-env
  MEMCACHE_SERVERS: ${MEMCACHE_SERVERS:-zammad-memcached:11211}
  POSTGRESQL_DB: ${POSTGRES_DB:-zammad_production}
  POSTGRESQL_HOST: ${POSTGRES_HOST:-zammad-postgresql}
  POSTGRESQL_USER: ${POSTGRES_USER:-zammad}
  POSTGRESQL_PASS: ${POSTGRES_PASS:-zammad}
  POSTGRESQL_PORT: ${POSTGRES_PORT:-5432}
  POSTGRESQL_OPTIONS: ${POSTGRESQL_OPTIONS:-?pool=50}
  POSTGRESQL_DB_CREATE:
  REDIS_URL: ${REDIS_URL:-redis://zammad-redis:6379}
  BACKUP_DIR: "${BACKUP_DIR:-/var/tmp/zammad}"
  BACKUP_TIME: "${BACKUP_TIME:-03:00}"
  HOLD_DAYS: "${HOLD_DAYS:-10}"
  TZ: "${TZ:-Europe/Berlin}"
  AUTOWIZARD_JSON:
  AUTOWIZARD_RELATIVE_PATH:
  ELASTICSEARCH_ENABLED:
  ELASTICSEARCH_SCHEMA:
  ELASTICSEARCH_HOST:
  ELASTICSEARCH_PORT:
  ELASTICSEARCH_USER:
  ELASTICSEARCH_PASS:
  ELASTICSEARCH_NAMESPACE:
  ELASTICSEARCH_REINDEX:
  NGINX_PORT:
  NGINX_CLIENT_MAX_BODY_SIZE:
  NGINX_SERVER_NAME:
  NGINX_SERVER_SCHEME:
  RAILS_TRUSTED_PROXIES:
  ZAMMAD_HTTP_TYPE:
  ZAMMAD_FQDN:
  ZAMMAD_WEB_CONCURRENCY:
  ZAMMAD_MANAGE_SESSIONS_JOBS_WORKERS:
  ZAMMAD_PROCESS_SESSIONS_JOBS_WORKERS:
  ZAMMAD_PROCESS_SCHEDULED_JOBS_WORKERS:
  ZAMMAD_PROCESS_DELAYED_JOBS_WORKERS:
  ZAMMAD_PROCESS_DELAYED_JOBS_WORKER_THREADS:
  ZAMMAD_PROCESS_DELAYED_AI_JOBS_WORKERS:
  ZAMMAD_PROCESS_DELAYED_AI_JOBS_WORKER_THREADS:
  ZAMMAD_PROCESS_DELAYED_COMMUNICATION_INBOUND_JOBS_WORKERS:
  ZAMMAD_PROCESS_DELAYED_COMMUNICATION_INBOUND_JOBS_WORKER_THREADS:

x-app-volumes: &app-volumes
  - zammad-backup:/var/tmp/zammad:ro
  - zammad-storage:/opt/zammad/storage

x-update-start-first: &update-start-first
  parallelism: 1
  order: start-first
  monitor: 30s
  failure_action: rollback

x-update-stop-first: &update-stop-first
  parallelism: 1
  order: stop-first
  monitor: 30s
  failure_action: rollback

services:
  zammad-railsserver:
    image: technewbyte/ndesk:${RELEASE_TAG:?defina RELEASE_TAG}
    command: ["zammad-railsserver"]
    environment: *app-env
    volumes: *app-volumes
    networks:
      ndesk-net:
        aliases: [zammad-railsserver]
    stop_grace_period: 30s
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:3000/ >/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 120s
    deploy:
      replicas: 1
      update_config: *update-start-first
      rollback_config:
        parallelism: 1
        order: start-first
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_RAILSSERVER_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_RAILSSERVER_RESOURCES_LIMITS_MEMORY:-500M}"

  zammad-nginx:
    image: technewbyte/ndesk:${RELEASE_TAG:?defina RELEASE_TAG}
    command: ["zammad-nginx"]
    environment: *app-env
    volumes: *app-volumes
    ports:
      - "${NGINX_EXPOSE_PORT:-8080}:${NGINX_PORT:-8080}"
    networks:
      ndesk-net:
        aliases: [zammad-nginx]
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/ >/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 120s
    deploy:
      replicas: 1
      update_config: *update-start-first
      rollback_config:
        parallelism: 1
        order: start-first
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_NGINX_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_NGINX_RESOURCES_LIMITS_MEMORY:-500M}"

  zammad-websocket:
    image: technewbyte/ndesk:${RELEASE_TAG:?defina RELEASE_TAG}
    command: ["zammad-websocket"]
    environment: *app-env
    volumes: *app-volumes
    networks:
      ndesk-net:
        aliases: [zammad-websocket]
    healthcheck:
      test: ["CMD", "bash", "-c", "</dev/tcp/127.0.0.1/6042"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 120s
    deploy:
      replicas: 1
      update_config: *update-start-first
      rollback_config:
        parallelism: 1
        order: start-first
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_WEBSOCKET_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_WEBSOCKET_RESOURCES_LIMITS_MEMORY:-500M}"

  zammad-scheduler:
    # stop-first: NUNCA duas instâncias (o scheduler cron-like dispararia jobs em dobro).
    # Sem healthcheck: não expõe porta; o gap de segundos no background é aceito (spec).
    image: technewbyte/ndesk:${RELEASE_TAG:?defina RELEASE_TAG}
    command: ["zammad-scheduler"]
    environment: *app-env
    volumes: *app-volumes
    networks:
      ndesk-net:
        aliases: [zammad-scheduler]
    stop_grace_period: 60s
    deploy:
      replicas: 1
      update_config: *update-stop-first
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_SCHEDULER_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_SCHEDULER_RESOURCES_LIMITS_MEMORY:-500M}"

  zammad-backup:
    image: technewbyte/ndesk:${RELEASE_TAG:?defina RELEASE_TAG}
    command: ["zammad-backup"]
    environment: *app-env
    user: "0:0"
    volumes:
      - zammad-backup:/var/tmp/zammad
      - zammad-storage:/opt/zammad/storage
    networks:
      ndesk-net:
        aliases: [zammad-backup]
    deploy:
      replicas: 1
      update_config: *update-stop-first
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_BACKUP_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_BACKUP_RESOURCES_LIMITS_MEMORY:-500m}"

  zammad-postgresql:
    image: postgres:${POSTGRES_VERSION:-17.9-alpine}
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-zammad_production}
      POSTGRES_USER: ${POSTGRES_USER:-zammad}
      POSTGRES_PASSWORD: ${POSTGRES_PASS:-zammad}
    volumes:
      - postgresql-data:/var/lib/postgresql/data
    networks:
      ndesk-net:
        aliases: [zammad-postgresql]
    deploy:
      replicas: 1
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_POSTGRESQL_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_POSTGRESQL_RESOURCES_LIMITS_MEMORY:-500M}"

  zammad-redis:
    image: redis:${REDIS_VERSION:-8.6.1-alpine}
    volumes:
      - redis-data:/data
    networks:
      ndesk-net:
        aliases: [zammad-redis]
    deploy:
      replicas: 1
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_REDIS_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_REDIS_RESOURCES_LIMITS_MEMORY:-500M}"

  zammad-memcached:
    image: memcached:${MEMCACHE_VERSION:-1.6.40-alpine}
    command: memcached -m 256M
    networks:
      ndesk-net:
        aliases: [zammad-memcached]
    deploy:
      replicas: 1
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_MEMCACHED_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_MEMCACHED_RESOURCES_LIMITS_MEMORY:-500M}"

  zammad-elasticsearch:
    image: elasticsearch:${ELASTICSEARCH_VERSION:-9.3.1}
    environment:
      discovery.type: single-node
      xpack.security.enabled: "false"
      ES_JAVA_OPTS: ${ELASTICSEARCH_JAVA_OPTS:--Xms1g -Xmx1g}
    volumes:
      - elasticsearch-data:/usr/share/elasticsearch/data
    networks:
      ndesk-net:
        aliases: [zammad-elasticsearch]
    deploy:
      replicas: 1
      restart_policy:
        condition: any
      resources:
        limits:
          cpus: "${ZAMMAD_ELASTICSEARCH_RESOURCES_LIMITS_CPUS:-1.0}"
          memory: "${ZAMMAD_ELASTICSEARCH_RESOURCES_LIMITS_MEMORY:-1G}"

  cloudflare-tunnel:
    # No ensaio (VM), CLOUDFLARE_TUNNEL_REPLICAS=0 no .env — o token de prod NUNCA
    # roda fora de prod (o tunnel roubaria tráfego real do helpdesk).
    image: cloudflare/cloudflared
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN}
    networks:
      ndesk-net: {}
    deploy:
      replicas: ${CLOUDFLARE_TUNNEL_REPLICAS:-1}
      restart_policy:
        condition: any

networks:
  ndesk-net:
    external: true

volumes:
  postgresql-data:
    external: true
    name: zammad_postgresql-data
  redis-data:
    external: true
    name: zammad_redis-data
  elasticsearch-data:
    external: true
    name: zammad_elasticsearch-data
  zammad-storage:
    external: true
    name: zammad_zammad-storage
  zammad-backup:
    external: true
    name: zammad_zammad-backup
```

- [ ] **Step 3: Validar sintaxe/interpolação localmente**

```bash
RELEASE_TAG=nb.smoke docker compose -f deploy/stack.yml config -q
```

Expected: exit 0, sem erros (warnings de variável não definida são aceitáveis — em produção vêm do `.env`). Confirmar também que sem `RELEASE_TAG` falha:

```bash
docker compose -f deploy/stack.yml config -q 2>&1 | grep -c 'defina RELEASE_TAG'
```

Expected: `1` (a trava `:?` funciona).

- [ ] **Step 4: Commit**

```bash
git add deploy/stack.yml
git commit -m "feat(deploy): stack Swarm do prod-ndesk com rolling start-first e healthchecks"
```

---

### Task 2: Script de deploy no servidor (`deploy/deploy.sh`)

**Files:**
- Create: `deploy/deploy.sh`

**Interfaces:**
- Consumes: `deploy/stack.yml` (Task 1, mesmo diretório); `/opt/zammad/.env` no servidor; imagem `technewbyte/ndesk:<tag>` no Docker Hub.
- Produces: CLI `deploy.sh <tag> [--maintenance|--skip-migrate]`, exit 0 = deploy convergido + smoke OK. O workflow (Task 3) chama `bash /opt/ndesk/deploy/deploy.sh`; o runbook de cutover (Task 4) chama com `--skip-migrate`. Variável opcional `SMOKE_URL` no `.env` sobrepõe a URL do smoke test (usada no ensaio).

- [ ] **Step 1: Escrever `deploy/deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Deploy do NDesk no Swarm single-node (ADR docs/deploy/adr/0001).
# Uso:
#   deploy.sh <tag>                 Deploy quente (padrão): migra antes, troca rolling
#   deploy.sh <tag> --maintenance   Janela de manutenção: PARA o app, migra, sobe
#   deploy.sh <tag> --skip-migrate  Cutover/redeploy sem migração (mesma versão)

TAG="${1:?uso: deploy.sh <tag> [--maintenance|--skip-migrate]}"
MODE="${2:-}"

STACK=ndesk
NETWORK=ndesk-net
IMAGE="technewbyte/ndesk:${TAG}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=/opt/zammad/.env
APP_SERVICES=(zammad-railsserver zammad-nginx zammad-websocket zammad-scheduler zammad-backup)

log() { echo "[deploy $(date -u +%H:%M:%S)] $*"; }

[ -f "$ENV_FILE" ] || { log "ERRO: ${ENV_FILE} não existe"; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export RELEASE_TAG="$TAG"
SMOKE_URL="${SMOKE_URL:-https://${ZAMMAD_FQDN:?ZAMMAD_FQDN ausente no .env}/}"

ensure_network() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 \
    || docker network create --driver overlay --attachable "$NETWORK"
}

pull_image() {
  log "pull ${IMAGE}"
  docker pull "$IMAGE"
}

run_migration() {
  log "migração pré-troca com ${IMAGE} (stack atual continua servindo)"
  docker run --rm --network "$NETWORK" \
    -e POSTGRESQL_DB="${POSTGRES_DB:-zammad_production}" \
    -e POSTGRESQL_HOST=zammad-postgresql \
    -e POSTGRESQL_USER="${POSTGRES_USER:-zammad}" \
    -e POSTGRESQL_PASS="${POSTGRES_PASS:-zammad}" \
    -e POSTGRESQL_PORT="${POSTGRES_PORT:-5432}" \
    -e POSTGRESQL_OPTIONS="${POSTGRESQL_OPTIONS:-?pool=50}" \
    -e REDIS_URL="${REDIS_URL:-redis://zammad-redis:6379}" \
    -e MEMCACHE_SERVERS="${MEMCACHE_SERVERS:-zammad-memcached:11211}" \
    -e TZ="${TZ:-America/Sao_Paulo}" \
    "$IMAGE" \
    bash -c 'bundle exec rake db:migrate && bundle exec rails r "Locale.sync; Translation.sync"'
}

stop_app() {
  log "JANELA DE MANUTENÇÃO: parando serviços de app"
  docker service scale --detach=false \
    "${STACK}_zammad-railsserver=0" \
    "${STACK}_zammad-nginx=0" \
    "${STACK}_zammad-websocket=0" \
    "${STACK}_zammad-scheduler=0"
}

deploy_stack() {
  log "stack deploy → ${TAG}"
  docker stack config -c "${DEPLOY_DIR}/stack.yml" \
    | docker stack deploy --detach=false -c - "$STACK"
}

wait_converged() {
  log "aguardando convergência (timeout 600s)"
  local deadline=$((SECONDS + 600))
  local line s ok
  while true; do
    ok=1
    for s in "${APP_SERVICES[@]}"; do
      line=$(docker service ls --filter "name=${STACK}_${s}" --format '{{.Replicas}} {{.Image}}')
      [[ "$line" == 1/1\ "${IMAGE}"* ]] || { ok=0; break; }
    done
    if [ "$ok" = 1 ]; then
      log "convergiu: todos os serviços de app em ${TAG}"
      return 0
    fi
    if (( SECONDS > deadline )); then
      log "ERRO: sem convergência em 600s — estado atual (provável rollback automático do Swarm):"
      docker service ls
      return 1
    fi
    sleep 5
  done
}

post_swap() {
  log "cache clear pós-troca"
  local cid
  cid=$(docker ps -q --filter "name=${STACK}_zammad-railsserver" | head -n1)
  [ -n "$cid" ] || { log "ERRO: container do railsserver não encontrado"; return 1; }
  docker exec "$cid" bundle exec rails r 'Rails.cache.clear'
  log "smoke test ${SMOKE_URL}"
  curl -sfo /dev/null -m 30 "$SMOKE_URL"
  log "smoke OK — deploy da ${TAG} concluído"
}

ensure_network
pull_image
case "$MODE" in
  --maintenance)  stop_app; run_migration ;;
  --skip-migrate) log "pulando migração (--skip-migrate)" ;;
  "")             run_migration ;;
  *)              log "ERRO: modo desconhecido '${MODE}'"; exit 64 ;;
esac
deploy_stack
wait_converged
post_swap
```

- [ ] **Step 2: Validar com bash -n e shellcheck**

```bash
bash -n deploy/deploy.sh && shellcheck deploy/deploy.sh
```

Expected: exit 0, nenhum warning (o SC1090 do `source` dinâmico já está suprimido inline).

- [ ] **Step 3: Commit**

```bash
git add deploy/deploy.sh
git commit -m "feat(deploy): deploy.sh — pull, migração pré-troca, stack deploy com convergência e smoke"
```

---

### Task 3: Workflow de build+deploy (`.github/workflows/docker-build.yml`)

**Files:**
- Modify: `.github/workflows/docker-build.yml` (reescrita completa do arquivo)

**Interfaces:**
- Consumes: `deploy/` (Tasks 1–2) via scp; secrets existentes `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `SSH_PRIVATE_KEY`; contrato `bash /opt/ndesk/deploy/deploy.sh <tag> [--maintenance]`.
- Produces: push de tag `nb.*` → build + deploy quente automático; `workflow_dispatch(tag, maintenance)` → deploy de qualquer Release publicada (rollback/redeploy/janela). Job `build` inalterado no comportamento (continua publicando a tag + `latest`).

- [ ] **Step 1: Reescrever o arquivo completo**

```yaml
name: Build and Deploy

on:
  push:
    branches: [newbyte-stable]
    tags: ['nb.*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag da Release (nb.*) já publicada para deployar — rollback = tag anterior'
        required: true
      maintenance:
        description: 'Janela de manutenção (para o app ANTES de migrar — usar para migrações incompatíveis)'
        type: boolean
        default: false

jobs:
  build:
    if: github.event_name == 'push'
    runs-on: ubuntu-24.04
    outputs:
      image_tag: ${{ steps.tag.outputs.tag }}
    steps:
      - name: Checkout Code
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Determine image tag
        id: tag
        run: |
          if [[ "$GITHUB_REF" == refs/tags/* ]]; then
            echo "tag=${GITHUB_REF#refs/tags/}" >> $GITHUB_OUTPUT
          else
            echo "tag=sha-$(git rev-parse --short HEAD)" >> $GITHUB_OUTPUT
          fi

      - name: Stamp version with nb tag
        env:
          IMAGE_TAG: ${{ steps.tag.outputs.tag }}
        run: |
          base_version=$(cat VERSION | tr -d '[:space:]')
          echo "${base_version}-${IMAGE_TAG}" > VERSION

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          build-args: COMMIT_SHA=${{ github.sha }}
          push: true
          tags: |
            technewbyte/ndesk:${{ steps.tag.outputs.tag }}
            technewbyte/ndesk:latest

  deploy:
    runs-on: ubuntu-24.04
    needs: build
    if: >-
      !cancelled() &&
      ((github.event_name == 'push' && startsWith(github.ref, 'refs/tags/') && needs.build.result == 'success') ||
       (github.event_name == 'workflow_dispatch' && needs.build.result == 'skipped'))
    concurrency:
      group: deploy-prod-ndesk
      cancel-in-progress: false
    steps:
      - name: Checkout Code
        uses: actions/checkout@v6

      - name: Resolve release tag
        id: resolve
        env:
          INPUT_TAG: ${{ inputs.tag }}
        run: |
          if [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]; then
            TAG="$INPUT_TAG"
          else
            TAG="${GITHUB_REF#refs/tags/}"
          fi
          if ! [[ "$TAG" =~ ^nb\.[A-Za-z0-9._-]+$ ]]; then
            echo "Tag inválida: '$TAG' (esperado nb.<alfanumérico/./_/->)"; exit 1
          fi
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"

      - name: Sync deploy files to prod-ndesk
        uses: appleboy/scp-action@v1
        with:
          host: 5.161.125.64
          username: root
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          source: "deploy"
          target: "/opt/ndesk"

      - name: Deploy
        uses: appleboy/ssh-action@v1
        with:
          host: 5.161.125.64
          username: root
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          command_timeout: 30m
          script: |
            bash /opt/ndesk/deploy/deploy.sh "${{ steps.resolve.outputs.tag }}" ${{ inputs.maintenance == true && '--maintenance' || '' }}
```

- [ ] **Step 2: Validar com actionlint**

```bash
actionlint .github/workflows/docker-build.yml
```

Expected: exit 0, nenhum erro.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/docker-build.yml
git commit -m "feat(ci): deploy quente por tag nb.* + dispatch com tag/maintenance e concurrency serializada"
```

---

### Task 4: Runbooks (cutover, ensaio, operações manuais)

**Files:**
- Create: `docs/deploy/runbooks/cutover.md`
- Create: `docs/deploy/runbooks/rehearsal.md`
- Create: `docs/deploy/runbooks/manual-ops.md`

**Interfaces:**
- Consumes: contrato do `deploy.sh` (Task 2), nomes fixos do stack (Task 1).
- Produces: procedimentos executáveis pelos Tasks 5 (ensaio) e 7 (cutover de produção).

- [ ] **Step 1: Escrever `docs/deploy/runbooks/cutover.md`**

```markdown
# Runbook — Cutover compose → Swarm (prod-ndesk)

Janela agendada e anunciada (~minutos). Executar num horário de baixo movimento.
Pré-requisitos: PR do deploy mergeado; `deploy/` presente em `/opt/ndesk/deploy`
(rode o workflow uma vez com dispatch até o passo de scp, ou rsync manual:
`rsync -av deploy/ root@5.161.125.64:/opt/ndesk/deploy/`); backup do dia existente
no volume `zammad_zammad-backup` (e no S3).

## Passos

1. **Identificar a tag em produção** (o cutover NÃO muda a versão do app):
   `docker exec zammad-zammad-railsserver-1 cat VERSION`
   O sufixo é a tag (ex.: `7.0.0-nb.14` → `TAG=nb.14`). Se o sufixo for `sha-*`,
   crie antes uma tag `nb.*` desse commit e espere o build publicar.
2. **Derrubar o stack compose** (a janela começa aqui; volumes ficam intactos):
   `cd /opt/zammad && docker compose -f docker-compose.yml -f scenarios/add-cloudflare-tunnel.yml -f scenarios/apply-resource-limits.yml down`
3. **Ativar o Swarm:** `docker swarm init --advertise-addr 5.161.125.64`
4. **Firewall:** confirmar de FORA do host que as portas de Swarm (2377/tcp,
   7946/tcp+udp, 4789/udp) estão bloqueadas:
   `sudo nmap -sT -sU -p T:2377,T:7946,U:7946,U:4789 5.161.125.64`
   → `closed|filtered` para todas as portas listadas (o scan UDP exige root).
   Se abertas, bloquear no firewall Hetzner/ufw ANTES de seguir.
5. **Subir o stack** (mesma tag, sem migração — a janela acaba quando convergir):
   `bash /opt/ndesk/deploy/deploy.sh "$TAG" --skip-migrate`
6. **Verificar:**
   - `docker service ls` → todos `1/1`, imagem `technewbyte/ndesk:$TAG`
   - `curl -sf -o /dev/null -w '%{http_code}\n' https://<ZAMMAD_FQDN>/` → `200`
   - Login no app, abrir um ticket, confirmar indicador de websocket/presença
   - `docker service logs --since 5m ndesk_zammad-scheduler` → background rodando
7. **Evidência:** salvar `docker service ls` + smoke em `docs/deploy/evidence/`.

## Rollback do cutover

`docker stack rm ndesk`
`until docker network rm ndesk-net; do sleep 2; done`
`docker swarm leave --force`
`cd /opt/zammad && docker compose -f docker-compose.yml -f scenarios/add-cloudflare-tunnel.yml -f scenarios/apply-resource-limits.yml up -d`
(Volumes intactos; o app volta ao estado pré-cutover em ~1 restart clássico.)

## Pós-cutover

- O cron `s3-backup.sh` continua válido (o volume `zammad_zammad-backup` não mudou).
- Os arquivos compose de `/opt/zammad` ficam no lugar como rota de fuga. NÃO apagar.
- A partir daqui, todo deploy é pelo workflow (tag `nb.*` ou dispatch).
```

- [ ] **Step 2: Escrever `docs/deploy/runbooks/rehearsal.md`**

```markdown
# Runbook — Ensaio do cutover e do deploy quente (VM descartável)

Valida TUDO fora de produção: restore do backup S3, cutover, deploy quente com
curl-loop, rollback. Destruir a VM ao final.

## 1. VM

`hcloud server create --name ndesk-ensaio --type cpx41 --image ubuntu-24.04 --ssh-key <sua-chave>`
No host novo: `curl -fsSL https://get.docker.com | sh` (confere `docker --version` ≥ 29).

## 2. Replicar a config de produção

Copiar de prod para a VM, mesma árvore:
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

## 6. Ensaiar o rollback do cutover

Executar a seção "Rollback do cutover" do `cutover.md` na VM e confirmar que o
compose volta a servir em `:8080`. (Na VM, omitir `-f scenarios/add-cloudflare-tunnel.yml`
do `compose up`, como no §3 — com o token dummy o cloudflared entra em crash-loop.)

## 7. Encerrar

- Registrar achados + `/tmp/curl-loop.log` em `docs/deploy/evidence/` (commit).
- `hcloud server delete ndesk-ensaio`
```

- [ ] **Step 3: Escrever `docs/deploy/runbooks/manual-ops.md`**

```markdown
# Runbook — Operações manuais (ex-responsabilidades do zammad-init)

O serviço `zammad-init` não existe mais no Swarm; estes casos raros viram
operação manual no host (`prod-ndesk`).

## Primeiro install (banco vazio — só em desastre/ambiente novo)

```bash
docker run --rm --network ndesk-net \
  -e POSTGRESQL_HOST=zammad-postgresql -e POSTGRESQL_DB=zammad_production \
  -e POSTGRESQL_USER=<user> -e POSTGRESQL_PASS=<pass> -e POSTGRESQL_PORT=5432 \
  -e REDIS_URL=redis://zammad-redis:6379 \
  -e MEMCACHE_SERVERS=zammad-memcached:11211 \
  technewbyte/ndesk:<tag> \
  bash -c 'bundle exec rake db:create db:migrate db:seed'
```

## Reconfigurar Elasticsearch (es_url ficou persistido no banco; só se mudar o ES)

```bash
CID=$(docker ps -q --filter name=ndesk_zammad-railsserver | head -n1)
docker exec "$CID" bundle exec rails r \
  "Setting.set('es_url', 'http://zammad-elasticsearch:9200'); Setting.set('es_index', 'zammad')"
```

## Rebuild do índice de busca (índice sumiu/corrompeu ou ES novo)

```bash
CID=$(docker ps -q --filter name=ndesk_zammad-railsserver | head -n1)
docker exec "$CID" bundle exec rake zammad:searchindex:rebuild
```

## Restore de backup em produção (destrutivo — janela obrigatória)

1. Parar o app: `docker service scale ndesk_zammad-railsserver=0 ndesk_zammad-nginx=0 ndesk_zammad-websocket=0 ndesk_zammad-scheduler=0 ndesk_zammad-backup=0`
2. Semear `restore/` no volume de backup (ver rehearsal.md §3).
3. `docker service scale ndesk_zammad-backup=1` → acompanhar logs até "Restore completed".
4. Redeployar a tag desejada: `bash /opt/ndesk/deploy/deploy.sh <tag> --skip-migrate`
```

- [ ] **Step 4: Conferir consistência de nomes contra os Tasks 1–2**

Checar manualmente: stack `ndesk`, rede `ndesk-net`, serviços `ndesk_zammad-*`, volumes `zammad_*`, CLI `deploy.sh <tag> [--maintenance|--skip-migrate]`, `SMOKE_URL`. Nenhuma divergência.

- [ ] **Step 5: Commit**

```bash
git add docs/deploy/runbooks/
git commit -m "docs(deploy): runbooks de cutover, ensaio em VM e operações manuais"
```

---

### Task 5: Ensaio na VM (executa `rehearsal.md`)

**Files:**
- Create: `docs/deploy/evidence/2026-XX-XX-ensaio.md` (data real da execução)
- Modify: `deploy/stack.yml`, `deploy/deploy.sh`, runbooks — correções que o ensaio revelar

**Interfaces:**
- Consumes: runbook `rehearsal.md` (Task 4), acesso `hcloud` + `aws` (disponíveis na máquina local), backup em `s3://newbyte-backups/ndesk`.
- Produces: evidência do quase-zero (curl-loop limpo) + runbooks/arquivos corrigidos — pré-condição do cutover real (Task 7).

- [ ] **Step 1: Executar `docs/deploy/runbooks/rehearsal.md` de ponta a ponta** — seguir o runbook literalmente; onde a realidade divergir do escrito, anotar.
- [ ] **Step 2: Corrigir os achados** — aplicar as correções em `deploy/stack.yml`, `deploy/deploy.sh` e runbooks; repetir o passo do ensaio que falhou até passar.
- [ ] **Step 3: Registrar evidência** — criar `docs/deploy/evidence/2026-XX-XX-ensaio.md` com: data, tag usada, resumo dos passos, pico de memória no overlap, resultado do curl-loop (contagem de códigos: `awk '{print $2}' /tmp/curl-loop.log | sort | uniq -c`), achados e correções.
- [ ] **Step 4: Destruir a VM** — `hcloud server delete ndesk-ensaio`.
- [ ] **Step 5: Commit**

```bash
git add docs/deploy/evidence/ deploy/ docs/deploy/runbooks/
git commit -m "docs(deploy): evidência do ensaio em VM + correções do runbook"
```

---

### Task 6: PR e merge

**Files:**
- N/A (operação git)

**Interfaces:**
- Consumes: branch `feat/zero-downtime-deploy` com Tasks 1–5.
- Produces: `deploy/` + workflow na `newbyte-stable` — pré-condição do cutover (o workflow novo só vale depois do merge; até lá, deploys por tag continuam no fluxo antigo, que segue funcional porque o compose de `/opt/zammad` está intacto).

- [ ] **Step 1: Abrir o PR**

```bash
git push -u origin feat/zero-downtime-deploy
gh pr create --base newbyte-stable --title "feat(deploy): deploy quase-zero-downtime via Swarm single-node" \
  --body "Spec: docs/superpowers/specs/2026-07-23-zero-downtime-deploy-design.md
ADR: docs/deploy/adr/0001-swarm-single-node-para-deploy-quente.md
Ensaio: docs/deploy/evidence/ (curl-loop limpo na VM)

- deploy/stack.yml — stack Swarm, rolling start-first + healthchecks, volumes external
- deploy/deploy.sh — migração pré-troca, convergência, cache clear pós-troca, smoke
- workflow: tag nb.* → deploy quente; dispatch(tag, maintenance) → redeploy/rollback/janela
- runbooks: cutover, ensaio, operações manuais

Atenção: o cutover de produção (janela agendada) acontece DEPOIS do merge, via runbook."
```

- [ ] **Step 2: Review + merge** — seguir o fluxo normal de review do repo. Após o merge, confirmar que o push em `newbyte-stable` buildou imagem normalmente (job `build`) e que o job `deploy` foi **skipped** (não é tag).

---

### Task 7: Cutover de produção (executa `cutover.md`)

**Files:**
- Create: `docs/deploy/evidence/2026-XX-XX-cutover.md` (data real)

**Interfaces:**
- Consumes: runbook `cutover.md` mergeado; janela agendada e anunciada aos usuários; backup do dia confirmado no S3.
- Produces: produção rodando o stack `ndesk` no Swarm; compose antigo preservado como rota de fuga.

- [ ] **Step 1: Agendar e anunciar a janela** (baixo movimento; ~15 min de margem).
- [ ] **Step 2: Confirmar backup do dia** — `aws s3 ls s3://newbyte-backups/ndesk/ | tail -2` mostra o par de hoje.
- [ ] **Step 3: Executar `docs/deploy/runbooks/cutover.md`** passo a passo.
- [ ] **Step 4: Registrar evidência** em `docs/deploy/evidence/2026-XX-XX-cutover.md` (duração da janela, saída do `service ls`, smoke) e commitar em branch `docs/cutover-evidence` → PR.

---

### Task 8: Prova do deploy quente em produção

**Files:**
- Create: `docs/deploy/evidence/2026-XX-XX-primeiro-deploy-quente.md` (data real)
- Modify: `docs/superpowers/specs/2026-07-23-zero-downtime-deploy-design.md` (status → Implementado)

**Interfaces:**
- Consumes: primeira Release `nb.*` após o cutover.
- Produces: evidência pública de que a meta ("quase-zero") foi atingida; spec fechada.

- [ ] **Step 1: Antes de taggear a Release, ligar o curl-loop** (da máquina local, contra a URL pública):

```bash
while :; do
  printf '%s %s\n' "$(date -u +%T)" \
    "$(curl -s -o /dev/null -w '%{http_code}' -m 5 https://<ZAMMAD_FQDN>/)"
  sleep 1
done | tee /tmp/curl-loop-prod.log
```

- [ ] **Step 2: Criar a tag e acompanhar o workflow** — `git tag nb.<N> && git push origin nb.<N>`; acompanhar `gh run watch`.
- [ ] **Step 3: Validar o critério** — `awk '{print $2}' /tmp/curl-loop-prod.log | sort | uniq -c` → só 2xx/3xx durante a troca; websocket reconectou (verificar badge no app); versão nova no ar (`docker service ls` mostra a tag).
- [ ] **Step 4: Registrar evidência + fechar a spec** — criar o arquivo de evidência, mudar o Status da spec para "Implementado (evidência: docs/deploy/evidence/…)", commitar via PR.

---

## Self-review do plano (executado na escrita)

- **Cobertura da spec:** Seção 1 (topologia) → Task 1; Seção 2 (pipeline/healthchecks/migração) → Tasks 2–3; Seção 3 (cutover/rollback/validação) → Tasks 4–7; prova em produção → Task 8; trade-offs (memória no overlap, tunnel fora de prod) → verificações explícitas no ensaio.
- **Placeholders:** nenhum TBD; todos os arquivos têm conteúdo completo. `2026-XX-XX` nos nomes de evidência é intencional (data da execução real).
- **Consistência de nomes:** stack `ndesk`, rede `ndesk-net`, serviços `ndesk_zammad-*`, volumes `zammad_*`, `RELEASE_TAG`, `SMOKE_URL`, CLI `deploy.sh <tag> [--maintenance|--skip-migrate]` — idênticos nos Tasks 1, 2, 3 e 4.
