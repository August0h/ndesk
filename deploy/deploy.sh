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

# Preflight: o healthcheck do nginx no stack.yml usa a porta 8080 fixa.
# Se NGINX_PORT divergir, todo deploy faria rollback automático — falhar já.
if [ -n "${NGINX_PORT:-}" ] && [ "${NGINX_PORT}" != "8080" ]; then
  log "ERRO: NGINX_PORT=${NGINX_PORT} no .env diverge do healthcheck (8080) do stack.yml"
  exit 1
fi

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
