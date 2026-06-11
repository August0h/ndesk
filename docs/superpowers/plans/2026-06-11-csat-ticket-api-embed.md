# Embutir `satisfaction` no payload REST do ticket — Plano de Implementação

> **Para workers agênticos:** SUB-SKILL OBRIGATÓRIA: superpowers:subagent-driven-development (recomendado) ou superpowers:executing-plans. Steps usam checkbox (`- [ ]`).

**Goal:** Incluir o objeto `satisfaction` (nota/comentário/atendente) nas respostas de `GET /api/v1/tickets` e `GET /api/v1/tickets/:id`, cobrindo **GET puro** + `?expand`/`?full`/`?all`, sem gating (API admin). Mantém o `satisfaction_ratable` existente.

**Architecture:** Um helper único `Ticket#satisfaction_api_attributes(user)` (em `Ticket::Assets`) que devolve `{ 'satisfaction_ratable' => …, 'satisfaction' => …|nil }`. O `filter_unauthorized_attributes` (já presente) passa a usá-lo → cobre `?expand`/`?full`/`?all`. `TicketsController#show`/`#index` fazem `as_json.merge(helper)` no render default → cobre o GET puro. `index` ganha `.includes(satisfaction_rating: :agent)` contra N+1.

**Tech Stack:** Ruby on Rails, RSpec/FactoryBot, REST. Spec: `docs/superpowers/specs/2026-06-11-csat-ticket-api-embed-design.md`. ADR: `docs/csat/adr/0002`.

**Branch:** `feat/csat-legacy` (PR #19) — tudo isto vira **um 2º commit** (squash no fim).

**Nomes canônicos:** helper `Ticket#satisfaction_api_attributes(user)`; helper privado `Ticket#satisfaction_rating_payload`; chave do objeto: `satisfaction`; campos do objeto: `score`, `comment`, `agent_id`, `agent_name`, `group_id`, `created_at`.

---

## Task 0: Baseline

**Files:** nenhum.

- [ ] **Step 1: Branch + backend verde**

Run: `git rev-parse --abbrev-ref HEAD` → Esperado: `feat/csat-legacy`
Run: `RAILS_ENV=test bundle exec rails db:migrate` (idempotente; aplica as migrações de CSAT no test DB se faltarem)
Run: `bundle exec rspec spec/requests/ticket_satisfaction_ratable_spec.rb` → Esperado: PASS (o exposure do `satisfaction_ratable` está verde).

---

## Task 1: Helper + `satisfaction` nos caminhos de assets (`?expand`/`?full`/`?all`)

**Files:**
- Modify: `app/models/ticket/assets.rb`
- Test: `spec/requests/ticket_satisfaction_embed_spec.rb` (criar)

- [ ] **Step 1: Escrever o request spec que falha (caminho `?expand`)**

```ruby
# spec/requests/ticket_satisfaction_embed_spec.rb
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'Ticket payload: embedded satisfaction', :aggregate_failures, type: :request do
  let(:group)    { create(:group) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:admin)    { create(:admin, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

  before { Setting.set('csat_integration', true) }

  context 'when the ticket has a rating' do
    before { create(:ticket_satisfaction_rating, ticket:, customer:, score: 4, comment: 'Ótimo') }

    it 'embeds the satisfaction object on the expanded GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}?expand=true", as: :json
      expect(response).to have_http_status(:ok)
      sat = json_response['satisfaction']
      expect(sat).to include(
        'score'      => 4,
        'comment'    => 'Ótimo',
        'agent_id'   => agent.id,
        'agent_name' => agent.fullname,
        'group_id'   => group.id,
      )
      expect(sat['created_at']).to be_present
    end
  end

  context 'when the ticket has no rating' do
    it 'returns satisfaction as null on the expanded GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}?expand=true", as: :json
      expect(json_response).to have_key('satisfaction')
      expect(json_response['satisfaction']).to be_nil
    end
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_embed_spec.rb`
Esperado: FAIL (chave `satisfaction` ausente).

- [ ] **Step 3: Refatorar `filter_unauthorized_attributes` + adicionar o helper**

Em `app/models/ticket/assets.rb`, substituir o método `filter_unauthorized_attributes` (linhas 61–71) por:

```ruby
  def filter_unauthorized_attributes(attributes)
    filtered_attributes = super

    user = UserInfo.current_user_id.present? ? User.lookup(id: UserInfo.current_user_id) : nil
    filtered_attributes.merge(satisfaction_api_attributes(user))
  end

  # Satisfaction attributes for REST ticket payloads. Reused by the assets
  # filter above (?expand/?full/?all) and by TicketsController (plain GET).
  # `satisfaction_ratable` stays per-user + behind csat_integration (popup logic);
  # `satisfaction` (the rating data) is always exposed when a rating exists, for
  # admin API consumers (see docs/csat/adr/0002).
  def satisfaction_api_attributes(user)
    attrs = {}
    if user.present? && Setting.get('csat_integration')
      attrs['satisfaction_ratable'] = Ticket::SatisfactionRating.ratable?(ticket: self, user:)
    end
    attrs['satisfaction'] = satisfaction_rating_payload
    attrs
  end

  def satisfaction_rating_payload
    rating = satisfaction_rating
    return if rating.nil?

    {
      'score'      => rating.score,
      'comment'    => rating.comment,
      'agent_id'   => rating.agent_id,
      'agent_name' => rating.agent&.fullname,
      'group_id'   => rating.group_id,
      'created_at' => rating.created_at,
    }
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_embed_spec.rb`
Esperado: PASS (2 examples).

- [ ] **Step 5: Regressão — `satisfaction_ratable` continua funcionando + rubocop**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_ratable_spec.rb` → Esperado: PASS.
Run: `bundle exec rubocop app/models/ticket/assets.rb` → Esperado: sem offenses.

- [ ] **Step 6: Commit**

```bash
git add app/models/ticket/assets.rb spec/requests/ticket_satisfaction_embed_spec.rb
git commit -m "feat(csat): embed satisfaction object in ticket assets payload (expand/full/all)"
```

---

## Task 2: Cobrir o GET puro (`TicketsController#show` e `#index`) + N+1

**Files:**
- Modify: `app/controllers/tickets_controller.rb`
- Test: `spec/requests/ticket_satisfaction_embed_spec.rb` (estender)

- [ ] **Step 1: Estender o spec (GET puro + lista) — falha**

Adicionar, dentro do `context 'when the ticket has a rating'` (depois do exemplo de `?expand`):

```ruby
    it 'embeds the satisfaction object on the plain GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}", as: :json
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('satisfaction', 'score')).to eq(4)
      expect(json_response.dig('satisfaction', 'agent_name')).to eq(agent.fullname)
    end

    it 'embeds the satisfaction object per ticket on the plain list' do
      authenticated_as(admin)
      get '/api/v1/tickets', as: :json
      row = json_response.find { |t| t['id'] == ticket.id }
      expect(row).to be_present
      expect(row.dig('satisfaction', 'score')).to eq(4)
    end
```

E, dentro do `context 'when the ticket has no rating'`:

```ruby
    it 'returns satisfaction as null on the plain GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}", as: :json
      expect(json_response).to have_key('satisfaction')
      expect(json_response['satisfaction']).to be_nil
    end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_embed_spec.rb`
Esperado: FAIL nos novos (GET puro/lista não trazem `satisfaction` ainda).

- [ ] **Step 3: Render default do `show` + `index` mescla o helper**

Em `app/controllers/tickets_controller.rb`:

(a) No `index`, adicionar `.includes(satisfaction_rating: :agent)` ao scope (linhas 16–19):

```ruby
    tickets = TicketPolicy::ReadScope.new(current_user).resolve
                                     .includes(satisfaction_rating: :agent)
                                     .reorder(id: :asc)
                                     .offset(pagination.offset)
                                     .limit(pagination.limit)
```

(b) No `index`, trocar o render default (linha 41) `render json: tickets` por:

```ruby
    render json: tickets.map { |ticket| ticket.as_json.merge(ticket.satisfaction_api_attributes(current_user)) }
```

(c) No `show`, trocar o render default (linha 68) `render json: ticket` por:

```ruby
    render json: ticket.as_json.merge(ticket.satisfaction_api_attributes(current_user))
```

- [ ] **Step 4: Rodar e ver passar**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_embed_spec.rb`
Esperado: PASS (todos).

- [ ] **Step 5: Rubocop**

Run: `bundle exec rubocop app/controllers/tickets_controller.rb` → Esperado: sem offenses.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/tickets_controller.rb spec/requests/ticket_satisfaction_embed_spec.rb
git commit -m "feat(csat): embed satisfaction object in plain GET /tickets and /tickets/:id"
```

---

## Task 3: Docs + verificação + squash no 2º commit da #19

**Files:** docs (já escritos), nenhum código novo.

- [ ] **Step 1: Suíte de regressão CSAT + enumeração**

Run:
```bash
bundle exec rspec \
  spec/requests/ticket_satisfaction_embed_spec.rb \
  spec/requests/ticket_satisfaction_ratable_spec.rb \
  spec/requests/csat_ratings_spec.rb spec/requests/csat_surveys_spec.rb spec/requests/csat_stats_spec.rb \
  spec/models/ticket_spec.rb spec/models/user_spec.rb spec/models/role_spec.rb spec/models/system_report_spec.rb
```
Esperado: ALL PASS (o novo `satisfaction` não quebra a enumeração — é additive; `ticket_spec`/`user_spec` etc. continuam verdes).

- [ ] **Step 2: Lint final**

Run: `bundle exec rubocop app/models/ticket/assets.rb app/controllers/tickets_controller.rb spec/requests/ticket_satisfaction_embed_spec.rb` → Esperado: limpo.

- [ ] **Step 3: Squash em UM commit + incluir os docs (spec + ADR)**

```bash
# junta os 2 commits desta feature num só, e adiciona os docs
git reset --soft HEAD~2
git add app/models/ticket/assets.rb app/controllers/tickets_controller.rb \
        spec/requests/ticket_satisfaction_embed_spec.rb \
        docs/superpowers/specs/2026-06-11-csat-ticket-api-embed-design.md \
        docs/superpowers/plans/2026-06-11-csat-ticket-api-embed.md \
        docs/csat/adr/0002-satisfaction-embutida-no-payload-do-ticket.md
git commit -m "feat(csat): embed satisfaction object in GET /tickets and /tickets/:id

Inclui o objeto satisfaction (nota/comentário/atendente) no payload REST do
ticket — GET puro + expand/full/all — via helper único Ticket#satisfaction_api_attributes
reusado pelo filter_unauthorized_attributes e pelo TicketsController. Sem gating
(API admin; ver docs/csat/adr/0002). includes(satisfaction_rating: :agent) na lista.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Push (atualiza a #19 — 2 commits agora; SEM merge)**

Run: `git push origin feat/csat-legacy`

---

## Cobertura do spec (auto-revisão)

| Seção do spec | Task |
|---|---|
| objeto `satisfaction` (shape) | Task 1 (helper `satisfaction_rating_payload`) |
| cobertura `?expand`/`?full`/`?all` | Task 1 (`filter_unauthorized_attributes`) |
| cobertura GET puro | Task 2 (controller `as_json.merge`) |
| sem gating | Task 1 (`satisfaction` sem checagem de permissão) |
| `satisfaction_ratable` mantido (per-user) | Task 1 (helper) |
| N+1 na lista | Task 2 (`includes(satisfaction_rating: :agent)`) |
| ticket sem avaliação → `null` | Tasks 1 e 2 (specs) |
