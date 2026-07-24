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

# Preflight (whitelist): este script faz `source` no .env, então o bash INTERPRETA
# cada valor — não é só parsing. Um `;` executa o resto da linha durante o source
# (injeção de comando); `|`, `&`, `<`, `>`, `(`, `)`, aspas no meio do valor ou aspas
# não-terminadas quebram ou executam o parse. O compose é tolerante e não pega nada
# disso (achado do ensaio: ELASTICSEARCH_JAVA_OPTS=-Xms6g -Xmx6g rodava "-Xmx6g" como
# comando). Uma blacklist de espaço/$/backtick não cobre esse leque, então validamos
# por WHITELIST, por linha KEY=VALUE (após remover um comentário " #..." à direita):
#   valor vazio            → ok
#   valor começando com "  → tem de casar ^"[^"]*"$ (aspas duplas fechadas), senão flag
#   valor começando com '  → tem de casar ^'[^']*'$ (aspas simples fechadas), senão flag
#   valor sem aspas        → só o charset seguro [A-Za-z0-9_.,:/@+?%=-]; o resto exige aspas
# Falha ANTES de sourcear, listando só nº da linha + KEY (nunca o VALOR).
unsafe=$(awk 'match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
    key = substr($0, 1, RLENGTH - 1)
    v   = substr($0, RLENGTH + 1)
    sub(/[[:space:]]+#.*$/, "", v)
    if (v == "") next
    q = substr(v, 1, 1)
    if (q == "\"") { if (v ~ /^"[^"]*"$/) next }
    else if (q == "'\''") { if (v ~ /^'\''[^'\'']*'\''$/) next }
    else { if (v ~ /^[A-Za-z0-9_.,:\/@+?%=-]+$/) next }
    print NR ": " key "=..."
  }' "$ENV_FILE")
if [ -n "$unsafe" ]; then
  log "ERRO: linhas do ${ENV_FILE} inseguras para source em bash — use aspas (\" ou ') no valor ou remova caracteres fora do charset seguro:"
  echo "$unsafe"
  exit 1
fi

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

# Preflight: sem os limites reais no .env, o stack cairia nos defaults de 500M
# (railsserver com 3 workers e o ES com heap grande entrariam em OOM loop).
missing=()
for v in ZAMMAD_RAILSSERVER_RESOURCES_LIMITS_MEMORY ZAMMAD_NGINX_RESOURCES_LIMITS_MEMORY \
         ZAMMAD_WEBSOCKET_RESOURCES_LIMITS_MEMORY ZAMMAD_SCHEDULER_RESOURCES_LIMITS_MEMORY \
         ZAMMAD_BACKUP_RESOURCES_LIMITS_MEMORY ZAMMAD_POSTGRESQL_RESOURCES_LIMITS_MEMORY \
         ZAMMAD_REDIS_RESOURCES_LIMITS_MEMORY ZAMMAD_MEMCACHED_RESOURCES_LIMITS_MEMORY \
         ZAMMAD_ELASTICSEARCH_RESOURCES_LIMITS_MEMORY ELASTICSEARCH_JAVA_OPTS; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
if [ "${#missing[@]}" -gt 0 ]; then
  log "ERRO: variáveis obrigatórias ausentes no ${ENV_FILE}: ${missing[*]}"
  exit 1
fi

# Preflight: sem token, o tunnel sobe vazio e crash-loopa — e o wait_converged
# não o observa (só serviços de app); só o smoke pegaria, tarde demais.
if [ "${CLOUDFLARE_TUNNEL_REPLICAS:-1}" != "0" ] && [ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  log "ERRO: CLOUDFLARE_TUNNEL_TOKEN ausente no ${ENV_FILE} (e CLOUDFLARE_TUNNEL_REPLICAS != 0)"
  exit 1
fi

# Lock local: serializa contra execuções manuais concorrentes (o concurrency do
# GitHub Actions só cobre deploys via workflow).
exec 9>/var/lock/ndesk-deploy.lock
flock -n 9 || { log "ERRO: outro deploy em andamento (lock /var/lock/ndesk-deploy.lock)"; exit 1; }

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
    -e POSTGRESQL_HOST="${POSTGRES_HOST:-zammad-postgresql}" \
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
  # --resolve-image never: sem re-resolver digests de imagens mutáveis
  # (cloudflared/postgres/ES) — deploy quente não recria infra. A imagem do app já foi
  # puxada no pull_image; re-publicar uma tag nb.* existente NÃO é suportado
  # (Release é imutável — crie tag nova).
  docker stack config -c "${DEPLOY_DIR}/stack.yml" \
    | docker stack deploy --detach=false --resolve-image never -c - "$STACK"
}

wait_converged() {
  log "aguardando convergência (timeout 600s)"
  local deadline=$((SECONDS + 600))
  local line s ok
  while true; do
    ok=1
    for s in "${APP_SERVICES[@]}"; do
      line=$(docker service ls --filter "name=${STACK}_${s}" --format '{{.Replicas}} {{.Image}}')
      [[ "$line" == "1/1 ${IMAGE}" || "$line" == "1/1 ${IMAGE}@"* ]] || { ok=0; break; }
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
  local attempt
  for attempt in 1 2 3; do
    if curl -sfo /dev/null -m 30 "$SMOKE_URL"; then
      log "smoke OK — deploy da ${TAG} concluído"
      return 0
    fi
    log "smoke falhou (tentativa ${attempt}/3)"
    sleep 10
  done
  log "ERRO: smoke test falhou após 3 tentativas"
  return 1
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
