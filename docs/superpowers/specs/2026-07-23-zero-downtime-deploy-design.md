# Deploy quase-zero-downtime do ndesk — Design

**Data:** 2026-07-23
**Status:** Aprovado (brainstorming)
**Escopo:** Infraestrutura de deploy do `prod-ndesk` (5.161.125.64) + workflow `docker-build.yml`

## Problema

Todo deploy de uma tag `nb.*` derruba o app por minutos. O fluxo atual (GitHub Actions
→ build da imagem `technewbyte/ndesk` → SSH no host → `docker compose pull && up -d` em
`/opt/zammad`) recria todos os containers de uma vez: o `zammad-init` novo roda
`db:migrate` + cache clear + `Translation.sync` (vários boots de Rails), e o
`railsserver`/`nginx` novos ficam bloqueados no `check_zammad_ready` até o init terminar.
Durante essa janela inteira, nenhuma requisição é atendida — o que impede lançar versões
em horário comercial.

## Meta

**Quase-zero downtime:** deploy em horário comercial sem janela perceptível — no máximo
um blip de poucos segundos e reconexão automática do websocket. Upgrades pesados do
Zammad upstream (lotes de migração incompatíveis) continuam podendo usar janela agendada.

Fato que viabiliza a meta: migrações próprias do fork são raras (2 em 2026 — CSAT);
o deploy do dia a dia é código puro. E o Zammad já resolve nativamente o reload dos
browsers pós-update via `AppVersion.trigger_browser_reload` (`lib/app_version.rb`).

## Decisão

**Swarm single-node no host atual + pipeline de deploy em fases.** Alternativas
descartadas:

- **Blue-green com compose puro + flip no proxy:** controle total do switch, mas
  workflow com estado ("qual cor está ativa"), dobra de RAM por deploy e mais partes
  móveis para manter.
- **Só reordenar o fluxo atual (migração antes do `up -d`):** mínimo esforço, mas o
  downtime só cai para ~15–40s de boot do puma — blip perceptível, aquém da meta.

O Swarm dá rolling `start-first` nativo com roteamento apenas para tasks healthy e
rollback automático, num modelo que o time já opera na frota de produção.

## Seção 1 — Arquitetura e topologia do stack

O host `prod-ndesk` vira Swarm de nó único (`docker swarm init`). O stack `ndesk` é
definido em arquivos versionados neste repo (diretório `deploy/`); o workflow os envia
ao servidor via rsync — acaba a edição manual de compose no host.

| Serviço | Estratégia de update | Observação |
|---|---|---|
| `railsserver` | rolling `start-first` + healthcheck | Novo sobe ao lado do antigo; só entra no balanceamento quando healthy |
| `nginx` | rolling `start-first` + healthcheck | Healthcheck atravessa o proxy até o rails — valida o caminho completo |
| `websocket` | `start-first` | Sessões no Redis (`REDIS_URL` já configurado); duas instâncias em overlap são seguras; clientes reconectam sozinhos |
| `scheduler` | `stop-first` | Nunca duas instâncias: o scheduler cron-like dispararia jobs em dobro. Gap de segundos no background é invisível |
| `postgresql`, `redis`, `memcached`, `cloudflared` (+ `elasticsearch`/`backup` se existirem) | imagem pinada, intocados | Spec não muda no deploy de app; o Swarm não os recria |

- **`zammad-init` deixa de existir como serviço.** Suas responsabilidades migram para o
  pipeline: migração vira job one-shot pré-troca; cache clear vira passo pós-troca.
- **`check_zammad_ready` permanece como rede de segurança:** deploy com migração
  pendente sem o job pré-troca → tasks novas nunca ficam healthy → Swarm faz rollback
  sozinho → produção intacta.
- **Volumes:** declarados `external` no stack file com os nomes atuais — dados
  reaproveitados, sem cópia.
- **Rede:** overlay única com o cloudflared dentro. O resolver dinâmico que o
  entrypoint do nginx configura funciona igual com o DNS do Swarm.

**Pendência de implementação:** confirmar via SSH o inventário exato de serviços e
volumes ativos em `/opt/zammad` (Elasticsearch? serviço de backup?). Não muda o design,
só o conteúdo do stack file.

## Seção 2 — Pipeline de deploy (GitHub Actions)

Trigger inalterado: tag `nb.*` builda e publica `technewbyte/ndesk:<tag>`. O job de
deploy é reescrito em quatro fases:

1. **Preparo** (stack antigo servindo): rsync dos arquivos de `deploy/` para o
   servidor; `docker pull` da imagem nova.
2. **Migração pré-troca** (stack antigo servindo): job one-shot com a imagem nova na
   rede do stack — `rake db:migrate` + `rails r 'Locale.sync; Translation.sync'`.
   Sem migração pendente é um no-op de ~30s. Falhou → workflow para, nada foi trocado.
3. **Troca rolling:** `docker stack deploy` com a tag nova. `start-first`: railsserver
   novo sobe, `check_zammad_ready` passa na hora (migração já rodou), healthcheck
   aprova, entra no balanceamento, antigo morre. Idem nginx/websocket; scheduler faz
   stop→start. O workflow espera convergência (poll em `docker service ps`) e falha se
   algum serviço não estabilizar — o Swarm já terá revertido (`failure_action: rollback`).
4. **Pós-troca:** `Rails.cache.clear` via `docker exec` no railsserver novo (depois da
   troca, não antes — o antigo já morreu e ninguém regrava entrada velha no memcached);
   o `AppVersion` notifica os browsers; smoke test com curl na URL pública esperando 200.

**Healthchecks / update config:**

- `railsserver`: `curl -sf http://localhost:3000/` — interval 10s, retries 3,
  `start_period` 60s (cobre o boot do puma).
- `nginx`: `curl -sf http://localhost:8080/` — atravessa o proxy.
- `update_config`: `order: start-first`, `parallelism: 1`, `monitor: 30s`,
  `failure_action: rollback`.

**Política de migração (disciplina que sustenta tudo):**

- Migrações próprias do fork: **expand/contract** — toda migração compatível com o
  código da versão anterior (adicionar coluna/tabela ok; renomear/dropar só em release
  posterior, quando nenhum código vivo referencia).
- Merges do upstream: revisar o lote de migrações no PR. Migração pesada/incompatível →
  caminho com janela: `workflow_dispatch` com flag `maintenance` fazendo o fluxo
  clássico stop-first fora do horário comercial.

## Seção 3 — Cutover, rollback e validação

**Cutover único (compose → Swarm), janela agendada:**

1. Antes: arquivos de `deploy/` prontos no repo, ensaio completo feito fora de produção.
2. No dia: `docker compose down` → `docker swarm init` → criar overlay → `docker stack
   deploy` com a **mesma tag já em produção** (cutover não mistura mudança de app com
   mudança de infra) → verificar healthy + smoke test.
3. Compose antigo fica intacto no host como rota de fuga: rollback do cutover =
   `docker stack rm ndesk && docker compose up -d`. Volumes externos e intocados.
4. Downtime do cutover ≈ um restart clássico (minutos), anunciado — a última janela
   não-agendada-por-migração do sistema.

**Rollback na operação normal:**

- Deploy que não fica healthy: Swarm reverte sozinho; workflow vermelho; usuário não viu.
- Deploy healthy mas funcionalmente quebrado: redeploy da tag anterior via
  `workflow_dispatch` (input de tag para deployar qualquer versão publicada).
  Expand/contract garante código antigo rodando no schema novo — rollback de app sem
  rollback de schema.
- Todas as fases idempotentes: rodar o workflow de novo é sempre seguro.

**Validação, em três degraus:**

1. **Ensaio local/VM:** Swarm num nó descartável com seed/dump sanitizado; pipeline
   inteiro executado; durante a troca, `curl` em loop de 1s — critério: zero respostas
   não-2xx/3xx durante o rolling.
2. **Ensaio do cutover:** partir do estado "compose rodando" e executar o runbook
   completo, incluindo o rollback de volta para compose.
3. **Prova em produção:** primeiro deploy `nb.*` pós-cutover com curl-loop externo
   durante a troca; log guardado como evidência do quase-zero.

## Fora de escopo

- Mover o ndesk para o cluster Swarm da frota (Traefik/Patroni) — descartado nesta
  rodada; o design fica contido no host atual.
- Réplicas múltiplas de `railsserver` para HA — possível evolução futura barata
  (o stack já estará em Swarm), mas não é requisito da meta atual.
- Zero absoluto em upgrades pesados do upstream — coberto por janela agendada.
