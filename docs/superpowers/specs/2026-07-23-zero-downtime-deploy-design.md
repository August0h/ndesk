# Deploy quase-zero-downtime do ndesk — Design

**Data:** 2026-07-23 (revisado após grill + inventário do servidor)
**Status:** Aprovado (brainstorming + grill-with-docs)
**Escopo:** Infraestrutura de deploy do `prod-ndesk` (5.161.125.64) + workflow `docker-build.yml`
**Glossário:** [docs/deploy/CONTEXT.md](../../deploy/CONTEXT.md)

## Problema

Todo deploy derruba o app por minutos. O fluxo atual (GitHub Actions → build da imagem
`technewbyte/ndesk` → SSH no host → `docker compose pull && up -d` em `/opt/zammad`)
recria todos os containers de uma vez: o `zammad-init` novo roda `db:migrate` + cache
clear + `Translation.sync` (vários boots de Rails), e o `railsserver`/`nginx` novos
ficam bloqueados no `check_zammad_ready` até o init terminar. Durante essa janela
inteira, nenhuma requisição é atendida — o que impede lançar Releases em horário
comercial.

Agravante encontrado no inventário: produção roda `technewbyte/ndesk:latest`
(`.env` com `VERSION=latest`), então não dá para saber qual versão está no ar olhando
o servidor, e rollback por tag não funciona de verdade.

## Meta

**Deploy quente** (ver glossário): deploy em horário comercial sem janela perceptível —
no máximo um blip de poucos segundos e reconexão automática do websocket. Mudanças
incompatíveis com isso (tipicamente lotes de migração pesados do upstream Zammad) usam
**Janela de manutenção** agendada.

Fatos que viabilizam a meta:

- Migrações próprias do fork são raras (2 em 2026 — CSAT); o deploy do dia a dia é
  código puro.
- O Zammad resolve nativamente o reload dos browsers pós-update via
  `AppVersion.trigger_browser_reload` (`lib/app_version.rb`).
- Sessões do websocket ficam no Redis quando `REDIS_URL` está setado
  (`config/application.rb:72`) — confirmado no env de produção.

## Decisão

**Swarm single-node no host atual + pipeline de deploy em fases.** Alternativas
descartadas:

- **Blue-green com compose puro + flip no proxy:** controle total do switch, mas
  workflow com estado ("qual cor está ativa"), dobra de RAM por deploy e mais partes
  móveis para manter.
- **Só reordenar o fluxo atual (migração antes do `up -d`):** mínimo esforço, mas o
  downtime só cai para ~15–40s de boot do puma — blip perceptível, aquém da meta.
- **Mover para o cluster Swarm da frota:** mudança maior com migração de dados;
  descartado nesta rodada (ver Fora de escopo).

O Swarm dá rolling `start-first` nativo com roteamento apenas para tasks healthy e
rollback automático, num modelo que o time já opera na frota de produção.

## Inventário de produção (confirmado via SSH em 2026-07-23)

- **Containers:** railsserver, nginx, websocket, scheduler, backup (todos
  `technewbyte/ndesk:latest`), cloudflared (token via `.env`), postgres:17.9-alpine,
  redis:8.6.1-alpine, elasticsearch:9.3.1 (6G heap), memcached:1.6.40-alpine.
- **Volumes:** `zammad_postgresql-data`, `zammad_redis-data`,
  `zammad_elasticsearch-data`, `zammad_zammad-storage`, `zammad_zammad-backup`.
- **Compose:** layout oficial zammad-docker-compose + `docker-compose.override.yml`
  (só `mem_limit`s) + scenarios `add-cloudflare-tunnel` e `apply-resource-limits`.
- **Backup:** serviço `zammad-backup` interno (06:00 UTC) + cron do host
  `s3-backup.sh` (07:00 UTC) que lê o volume `zammad_zammad-backup` **pelo nome** e
  envia para `s3://newbyte-backups/ndesk`.
- **Runtime:** Docker 29.3.0, `ZAMMAD_WEB_CONCURRENCY=3`, `REDIS_URL` presente.

## Seção 1 — Arquitetura e topologia do stack

O host `prod-ndesk` vira Swarm de nó único (`docker swarm init`). O stack `ndesk` é
definido em arquivos versionados neste repo (diretório `deploy/`); o workflow os envia
ao servidor por cópia dos arquivos (scp) — acaba a edição manual de compose no host
(não remove arquivos deletados do servidor).

| Serviço | Estratégia de update | Observação |
|---|---|---|
| `railsserver` | rolling `start-first` + healthcheck | Novo sobe ao lado do antigo; só entra no balanceamento quando healthy |
| `nginx` | rolling `start-first` + healthcheck | Healthcheck atravessa o proxy até o rails — valida o caminho completo |
| `websocket` | `start-first` | Sessões no Redis (confirmado); duas instâncias em overlap são seguras; clientes reconectam sozinhos |
| `scheduler` | `stop-first` | Nunca duas instâncias: o scheduler cron-like dispararia jobs em dobro. Gap de segundos no background é invisível |
| `backup` | `stop-first` | Job interno de backup às 06:00 UTC; sem impacto de user-facing |
| `postgresql`, `redis`, `memcached`, `elasticsearch`, `cloudflared` | imagem pinada, intocados | Spec não muda no deploy de app; o Swarm não os recria |

- **Imagem sempre pinada na tag da Release** (`technewbyte/ndesk:nb.X.Y`), nunca
  `latest`. O build continua publicando `latest`, mas produção não o referencia mais.
  `docker service ls` passa a mostrar a versão exata no ar.
- **`zammad-init` deixa de existir como serviço.** Suas responsabilidades migram para
  o pipeline: migração vira job one-shot pré-troca; cache clear vira passo pós-troca.
  (Consequência: o rebuild automático de índice do ES que o init fazia em índice
  ausente sai do fluxo — caso raro, vira runbook manual.)
- **`check_zammad_ready` permanece como rede de segurança:** deploy com migração
  pendente sem o job pré-troca → tasks novas nunca ficam healthy → Swarm faz rollback
  sozinho → produção intacta.
- **Volumes:** declarados `external` no stack file com os nomes atuais exatos — dados
  reaproveitados sem cópia, e o cron `s3-backup.sh` (que referencia
  `zammad_zammad-backup` pelo nome) continua funcionando sem mudança.
- **Rede:** overlay única com o cloudflared dentro. O resolver dinâmico que o
  entrypoint do nginx configura funciona igual com o DNS do Swarm.
- **Env:** `/opt/zammad/.env` continua sendo a fonte de configuração/segredos do host;
  o deploy injeta a tag da Release no stack file na hora do deploy (template).
  `mem_limit`s do override viram `deploy.resources.limits` no stack file.

## Seção 2 — Pipeline de deploy (GitHub Actions)

**Um único workflow** com dois gatilhos:

- Tag `nb.*` → build + Deploy quente automático da própria tag.
- `workflow_dispatch` com inputs `tag` (qual Release deployar — serve para rollback e
  redeploy de qualquer versão publicada) e `maintenance` (boolean, default false).

`concurrency` group serializa deploys: duas tags em sequência não brigam pelo stack —
o segundo deploy espera o primeiro.

**Deploy quente (caminho padrão), quatro fases:**

1. **Preparo** (stack antigo servindo): cópia dos arquivos (scp) de `deploy/` para o
   servidor (não remove arquivos deletados do servidor); `docker pull` da imagem nova.
2. **Migração pré-troca** (stack antigo servindo): job one-shot com a imagem nova na
   rede do stack — `rake db:migrate` + `rails r 'Locale.sync; Translation.sync'`.
   Sem migração pendente é um no-op de ~30s. Falhou → workflow para, nada foi trocado.
3. **Troca rolling:** `docker stack deploy` com a tag nova. `start-first`: railsserver
   novo sobe, `check_zammad_ready` passa na hora (migração já rodou), healthcheck
   aprova, entra no balanceamento, antigo morre. Idem nginx/websocket; scheduler faz
   stop→start. O workflow espera convergência (poll em `docker service ps`) e falha se
   algum serviço não estabilizar — o Swarm já terá revertido (`failure_action: rollback`).
4. **Pós-troca:** `Rails.cache.clear` via `docker exec` no railsserver novo (depois da
   troca — o antigo já morreu e ninguém regrava entrada velha no memcached); o
   `AppVersion` notifica os browsers; smoke test com curl na URL pública esperando
   resposta de sucesso (2xx/3xx).

**Janela de manutenção (`maintenance: true`) — a ordem inverte**, porque numa migração
incompatível o código antigo não pode estar servindo quando ela roda:

1. Serviços de app a 0 réplicas (railsserver/nginx/websocket/scheduler) — janela começa.
2. Job de migração com a imagem nova.
3. `docker stack deploy` com a tag nova — serviços voltam, janela acaba.

**Healthchecks / update config:**

- `railsserver`: `curl -sf http://localhost:3000/` — interval 10s, retries 3,
  `start_period` 120s (cobre o boot do puma).
- `nginx`: `curl -sf http://localhost:8080/` — atravessa o proxy.
- `update_config`: `order: start-first`, `parallelism: 1`, `monitor: 30s`,
  `failure_action: rollback`.

**Orientação de migração (sem processo formal — decisão do grill):**

Sem checklist obrigatório, gem ou CI de enforcement: o volume real (2 migrações
próprias/ano, sempre pequenas) não justifica. Fica só a regra de bolso, decidida no
bom senso de quem mergeia:

- Aditiva (coluna/tabela/índice) e rápida → Deploy quente.
- Destrutiva (rename/drop), backfill pesado ou DDL que segura lock em tabela grande →
  Janela de manutenção. Motivo: a migração roda contra o banco vivo; uma destrutiva
  quebra o código **antigo** ainda no ar, antes da troca — e a rede de segurança do
  healthcheck não cobre isso.
- Lotes de migração de merges do upstream → Janela de manutenção por padrão.

## Seção 3 — Cutover, rollback e validação

**Cutover único (compose → Swarm), janela agendada:**

1. Antes: arquivos de `deploy/` prontos no repo, ensaio completo feito fora de produção.
2. No dia: `docker compose down` → `docker swarm init` → criar overlay → `docker stack
   deploy` com a **mesma tag já em produção** (cutover não mistura mudança de app com
   mudança de infra) → verificar healthy + smoke test.
3. Compose antigo fica intacto no host como rota de fuga: rollback do cutover =
   `docker stack rm ndesk && docker compose up -d`. Volumes externos e intocados.
4. Downtime do cutover ≈ um restart clássico (minutos), anunciado — a última janela
   não planejada por migração que o sistema terá.

**Rollback na operação normal:**

- Deploy que não fica healthy: Swarm reverte sozinho; workflow vermelho; usuário não viu.
- Deploy healthy mas funcionalmente quebrado: redeploy da tag anterior via
  `workflow_dispatch` (input `tag`). Migrações aditivas garantem código antigo rodando
  no schema novo — rollback de app sem rollback de schema.
- Todas as fases idempotentes: rodar o workflow de novo é sempre seguro.

**Validação, em três degraus:**

1. **Ensaio em VM Hetzner descartável com restore do backup do S3** (decisão do
   grill): restaurar o backup mais recente de `s3://newbyte-backups/ndesk`, subir o
   stack compose igual produção e executar o runbook completo — cutover → deploy
   quente com curl-loop de 1s (critério: zero respostas não-2xx/3xx durante o
   rolling) → rollback para compose. Bônus deliberado: exercita o procedimento de
   restore do backup de ponta a ponta.
2. **Prova em produção:** primeiro deploy `nb.*` pós-cutover com curl-loop externo
   durante a troca; log guardado como evidência do quase-zero.

## Trade-offs aceitos

- **Janela de versões mistas (segundos):** durante o rolling, abas com HTML antigo
  podem tomar 404 em assets fingerprinted da versão antiga até o reload nativo do
  `AppVersion` disparar. Aceito: dura segundos, o produto já trata com reload, e a
  alternativa (dois conjuntos de assets servíveis ou sticky routing) é complexidade
  permanente para polir um efeito transitório.
- **Gap de segundos no background** no stop→start do scheduler a cada deploy.
- **Primeiro-install/autowizard e rebuild de índice ES** saem do fluxo automatizado
  (eram do init) — viram runbook manual para o caso raro.

## Fora de escopo

- Mover o ndesk para o cluster Swarm da frota (Traefik/Patroni).
- Réplicas múltiplas de `railsserver` para HA — evolução futura barata (o stack já
  estará em Swarm), mas não é requisito da meta atual.
- Zero absoluto em upgrades pesados do upstream — coberto por Janela de manutenção.
