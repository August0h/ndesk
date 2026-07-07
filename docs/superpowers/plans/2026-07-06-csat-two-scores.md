# CSAT — Duas dimensões (resolução + atendimento) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dividir a nota única do CSAT em duas notas 1–5 — Nota de Resolução e Nota de Atendimento — em banco, API REST e popup da UI clássica, mantendo a avaliação como registro único write-once.

**Architecture:** Rename da coluna `score` → `score_service` (o dado de produção vira Nota de Atendimento, ver ADR 0003) + nova coluna `score_resolution` (NULL nas linhas antigas) na mesma tabela `ticket_satisfaction_ratings`. Todos os consumidores do score (POST ratings, surveys, stats, embed no payload do ticket, modal Spine) passam a operar com o par simétrico. Spec aprovado: `docs/superpowers/specs/2026-07-06-csat-two-scores-design.md`.

**Tech Stack:** Rails 8 / PostgreSQL / RSpec (backend), Spine.js + CoffeeScript + eco + SCSS (UI clássica), gettext `.pot`/`.po` (i18n).

**⚠️ REGRA DE COMMIT DESTA FEATURE (override do padrão "frequent commits"):** o usuário pediu **commit único** com a feature inteira (incluindo spec + plano). **Nenhuma task intermediária faz commit** — o único `git commit` é o passo final da Task 9. A branch `feat/csat-two-scores` (criada de `origin/newbyte-stable`) já existe e está ativa.

**Contexto do repo para quem chega sem contexto:**
- Rodar specs: `bundle exec rspec <path>` (na raiz do repo).
- Migrações: `bundle exec rails db:migrate` (dev) e `RAILS_ENV=test bundle exec rails db:migrate` (banco de teste). `db/schema.rb` é git-ignored — não commitar.
- A UI clássica (CoffeeScript/eco) não tem teste automatizado para este modal; a validação é QA manual (Task 9) + `assets:precompile` (que é o que quebra o deploy do Coolify se houver erro de sintaxe CSS/Coffee).
- `json_response` é helper padrão dos request specs do repo.

---

### Task 1: Migração + modelo + factory

**Files:**
- Create: `db/migrate/20260706000001_split_csat_score_into_service_and_resolution.rb`
- Modify: `app/models/ticket/satisfaction_rating.rb`
- Modify: `spec/factories/ticket/satisfaction_rating.rb`
- Test: `spec/models/ticket/satisfaction_rating_spec.rb`

- [ ] **Step 1.1: Atualizar o model spec para o novo contrato (fica vermelho)**

Em `spec/models/ticket/satisfaction_rating_spec.rb`, substituir o bloco `describe 'validations'` inteiro por:

```ruby
  describe 'validations' do
    it 'requires a service score' do
      expect(build(:ticket_satisfaction_rating, score_service: nil)).not_to be_valid
    end

    it 'rejects a service score outside 1..5' do
      expect(build(:ticket_satisfaction_rating, score_service: 6)).not_to be_valid
    end

    it 'requires a resolution score on create' do
      expect(build(:ticket_satisfaction_rating, score_resolution: nil)).not_to be_valid
    end

    it 'rejects a resolution score outside 1..5' do
      expect(build(:ticket_satisfaction_rating, score_resolution: 0)).not_to be_valid
    end

    it 'keeps legacy rows (without resolution score) valid outside the create context' do
      legacy = create(:ticket_satisfaction_rating, :legacy, ticket:, customer:)
      expect(legacy.reload).to be_valid
    end

    it 'forbids a second rating for the same ticket+customer' do
      rating
      dup = build(:ticket_satisfaction_rating, ticket:, customer:)
      expect(dup).not_to be_valid
    end
  end
```

Substituir o bloco `describe 'immutability (attr_readonly)'` inteiro por:

```ruby
  describe 'immutability (attr_readonly)' do
    subject(:rating) { create(:ticket_satisfaction_rating, ticket:, customer:, score_service: 3, score_resolution: 4) }

    # Under load_defaults 8.0, assigning a readonly attribute on a persisted
    # record raises rather than silently ignoring the change.
    it 'does not persist a changed service score' do
      aggregate_failures do
        expect { rating.update(score_service: 1) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
        expect(rating.reload.score_service).to eq(3)
      end
    end

    it 'does not persist a changed resolution score' do
      aggregate_failures do
        expect { rating.update(score_resolution: 1) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
        expect(rating.reload.score_resolution).to eq(4)
      end
    end
  end
```

E no comentário do bloco `describe 'associations'` (linha ~14), trocar
`ticket_id/customer_id/agent_id/score` por `ticket_id/customer_id/agent_id/score_service/score_resolution`.

- [ ] **Step 1.2: Rodar o spec para confirmar que falha**

Run: `bundle exec rspec spec/models/ticket/satisfaction_rating_spec.rb`
Expected: FAIL — erros de atributo desconhecido `score_service` (coluna/factory ainda não existem).

- [ ] **Step 1.3: Criar a migração**

Criar `db/migrate/20260706000001_split_csat_score_into_service_and_resolution.rb`:

```ruby
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class SplitCsatScoreIntoServiceAndResolution < ActiveRecord::Migration[8.0]
  def change
    # O score único de produção sempre teve semântica de atendimento — o popup
    # perguntava "Como foi o seu atendimento?" (ver docs/csat/adr/0003).
    rename_column :ticket_satisfaction_ratings, :score, :score_service
    # NULL = avaliação registrada antes da dimensão de resolução existir.
    add_column :ticket_satisfaction_ratings, :score_resolution, :integer, null: true
  end
end
```

- [ ] **Step 1.4: Rodar as migrações (dev + test)**

Run: `bundle exec rails db:migrate && RAILS_ENV=test bundle exec rails db:migrate`
Expected: `SplitCsatScoreIntoServiceAndResolution: migrated` nos dois bancos, sem erro.

- [ ] **Step 1.5: Atualizar o modelo**

Em `app/models/ticket/satisfaction_rating.rb`, substituir:

```ruby
  validates :score, presence: true, inclusion: { in: 1..5 }
  validates :ticket_id, uniqueness: { scope: :customer_id }

  # write-once: never mutate after registration
  attr_readonly :ticket_id, :customer_id, :agent_id, :score
```

por:

```ruby
  validates :score_service, presence: true, inclusion: { in: 1..5 }
  # on: :create — linhas legadas (pré-dimensão, score_resolution NULL) continuam
  # válidas se algum fluxo futuro as regravar (ex.: comment, que não é readonly)
  validates :score_resolution, presence: true, inclusion: { in: 1..5 }, on: :create
  validates :ticket_id, uniqueness: { scope: :customer_id }

  # write-once: never mutate after registration
  attr_readonly :ticket_id, :customer_id, :agent_id, :score_service, :score_resolution
```

- [ ] **Step 1.6: Atualizar a factory (com trait :legacy)**

Substituir o conteúdo inteiro de `spec/factories/ticket/satisfaction_rating.rb` por:

```ruby
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

FactoryBot.define do
  factory :'ticket/satisfaction_rating', aliases: %i[ticket_satisfaction_rating] do
    ticket
    customer         { association(:customer) }
    score_service    { Faker::Number.between(from: 1, to: 5) } # rubocop:disable Zammad/FakerUnique -- scores intentionally repeat across the 1..5 range
    score_resolution { Faker::Number.between(from: 1, to: 5) } # rubocop:disable Zammad/FakerUnique -- scores intentionally repeat across the 1..5 range
    comment          { nil }
    created_by_id    { 1 }
    updated_by_id    { 1 }

    trait :with_comment do
      comment { 'Excellent service!' }
    end

    # Avaliação gravada antes da dimensão de resolução existir (produção pré-rename).
    # Bypass do save via validate: false porque a presença é exigida on: :create.
    trait :legacy do
      score_resolution { nil }
      to_create { |instance| instance.save!(validate: false) }
    end
  end
end
```

- [ ] **Step 1.7: Rodar o model spec até verde**

Run: `bundle exec rspec spec/models/ticket/satisfaction_rating_spec.rb`
Expected: PASS (todos os exemplos).

**SEM COMMIT** (commit único na Task 9).

---

### Task 2: POST /api/v1/csat/ratings

**Files:**
- Modify: `app/controllers/csat_ratings_controller.rb`
- Test: `spec/requests/csat_ratings_spec.rb`

- [ ] **Step 2.1: Atualizar o request spec (fica vermelho)**

Substituir o conteúdo inteiro de `spec/requests/csat_ratings_spec.rb` por:

```ruby
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'CSAT ratings API', type: :request do
  let(:group)    { create(:group) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

  before { Setting.set('csat_integration', true) }

  it 'lets the ticket customer create a rating (credited to the owner)' do
    authenticated_as(customer)
    expect do
      post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 5, comment: 'Ótimo' }, as: :json
    end.to change(Ticket::SatisfactionRating, :count).by(1)
    expect(response).to have_http_status(:created)
    rating = Ticket::SatisfactionRating.last
    expect(rating.score_service).to eq(4)
    expect(rating.score_resolution).to eq(5)
    expect(rating.agent_id).to eq(agent.id)
    expect(json_response).to include('score_service' => 4, 'score_resolution' => 5)
  end

  it 'rejects a submission missing the resolution score' do
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects a submission missing the service score' do
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects a legacy-form submission that only sends score (deploy window)' do
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score: 4 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'forbids a non-customer (agent)' do
    authenticated_as(agent)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'forbids rating an open ticket' do
    ticket.update!(state: Ticket::State.find_by(name: 'open'))
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'forbids a second rating' do
    create(:ticket_satisfaction_rating, ticket:, customer:)
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'drops the comment when csat_comment is off' do
    Setting.set('csat_comment', 'off')
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 5, score_resolution: 5, comment: 'x' }, as: :json
    expect(response).to have_http_status(:created)
    expect(Ticket::SatisfactionRating.last.comment).to be_nil
  end
end
```

- [ ] **Step 2.2: Rodar e confirmar falha**

Run: `bundle exec rspec spec/requests/csat_ratings_spec.rb`
Expected: FAIL — controller ainda seta `score:` (atributo inexistente) e serializa `score`.

- [ ] **Step 2.3: Atualizar o controller**

Em `app/controllers/csat_ratings_controller.rb`, substituir o método `create` e o `serialize` (o `comment_value` fica como está):

```ruby
  # POST /api/v1/csat/ratings
  def create
    rating = ::Ticket::SatisfactionRating.new(
      ticket:           Ticket.find(params[:ticket_id]),
      customer:         current_user,
      score_service:    params[:score_service],
      score_resolution: params[:score_resolution],
      comment:          comment_value(params[:comment]),
    )

    authorize!(rating, :create?)
    rating.save!

    render json: serialize(rating), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
```

```ruby
  def serialize(rating)
    {
      id:               rating.id,
      ticket_id:        rating.ticket_id,
      score_service:    rating.score_service,
      score_resolution: rating.score_resolution,
      comment:          rating.comment,
      created_at:       rating.created_at,
    }
  end
```

Sem alias para o param antigo `score` — decisão de design: com ambas obrigatórias, uma
aba pré-deploy tomaria 422 de qualquer forma. Nada é gravado; se o cliente fechar o modal
após o erro, a dispensa via LocalStorage suprime o popup daquele ticket — no pior caso
perde-se essa uma avaliação. Janela minúscula, perda aceita.

- [ ] **Step 2.4: Rodar até verde**

Run: `bundle exec rspec spec/requests/csat_ratings_spec.rb`
Expected: PASS.

**SEM COMMIT.**

---

### Task 3: GET /api/v1/csat/surveys

**Files:**
- Modify: `app/controllers/csat_surveys_controller.rb`
- Test: `spec/requests/csat_surveys_spec.rb`

- [ ] **Step 3.1: Atualizar o request spec (fica vermelho)**

Substituir o conteúdo inteiro de `spec/requests/csat_surveys_spec.rb` por:

```ruby
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'CSAT surveys API', :aggregate_failures, type: :request do
  let(:group)    { create(:group) }
  let(:admin)    { create(:admin) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }

  before do
    Setting.set('csat_integration', true)
    3.times do
      ticket = create(:ticket, group:, customer:, owner: agent, state:)
      create(:ticket_satisfaction_rating, ticket:, customer:, score_service: 5, score_resolution: 4)
    end
  end

  it 'returns ratings with both scores to an admin' do
    authenticated_as(admin)
    get '/api/v1/csat/surveys', as: :json
    expect(response).to have_http_status(:ok)
    expect(json_response).to be_a(Array)
    expect(json_response.size).to eq(3)
    expect(json_response.first).to include('score_service' => 5, 'score_resolution' => 4, 'agent_id' => agent.id)
  end

  it 'serializes a legacy rating with a null resolution score' do
    ticket = create(:ticket, group:, customer:, owner: agent, state:)
    create(:ticket_satisfaction_rating, :legacy, ticket:, customer:, score_service: 3)
    authenticated_as(admin)
    get '/api/v1/csat/surveys', as: :json
    legacy = json_response.find { |r| r['score_service'] == 3 }
    expect(legacy).to be_present
    expect(legacy['score_resolution']).to be_nil
  end

  it 'paginates' do
    authenticated_as(admin)
    get '/api/v1/csat/surveys?per_page=2&page=1', as: :json
    expect(json_response.size).to eq(2)
  end

  it 'filters by agent_id' do
    authenticated_as(admin)
    get "/api/v1/csat/surveys?agent_id=#{agent.id}", as: :json
    expect(json_response.size).to eq(3)
    get '/api/v1/csat/surveys?agent_id=0', as: :json
    expect(json_response.size).to eq(0)
  end

  it 'filters by score_service and score_resolution' do
    authenticated_as(admin)
    get '/api/v1/csat/surveys?score_service=5', as: :json
    expect(json_response.size).to eq(3)
    get '/api/v1/csat/surveys?score_resolution=4', as: :json
    expect(json_response.size).to eq(3)
    get '/api/v1/csat/surveys?score_resolution=1', as: :json
    expect(json_response.size).to eq(0)
  end

  it 'forbids a non-admin' do
    authenticated_as(agent)
    get '/api/v1/csat/surveys', as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
```

- [ ] **Step 3.2: Rodar e confirmar falha**

Run: `bundle exec rspec spec/requests/csat_surveys_spec.rb`
Expected: FAIL — serializer ainda expõe `score` e o filtro `score_service` é ignorado.

- [ ] **Step 3.3: Atualizar o controller**

Em `app/controllers/csat_surveys_controller.rb`, no método `scope`, trocar a linha:

```ruby
    %i[agent_id group_id score].each do |attribute|
```

por:

```ruby
    %i[agent_id group_id score_service score_resolution].each do |attribute|
```

E no `serialize`, trocar a linha `score:       rating.score,` pelo par:

```ruby
      score_service:    rating.score_service,
      score_resolution: rating.score_resolution,
```

(mantendo as demais chaves como estão).

- [ ] **Step 3.4: Rodar até verde**

Run: `bundle exec rspec spec/requests/csat_surveys_spec.rb`
Expected: PASS.

**SEM COMMIT.**

---

### Task 4: GET /api/v1/csat/stats (service + request)

**Files:**
- Modify: `app/services/service/csat/stats.rb`
- Test: `spec/services/service/csat/stats_spec.rb`
- Test: `spec/requests/csat_stats_spec.rb`

- [ ] **Step 4.1: Atualizar o service spec (fica vermelho)**

Substituir o conteúdo inteiro de `spec/services/service/csat/stats_spec.rb` por:

```ruby
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Service::Csat::Stats, :aggregate_failures do
  let(:group)    { create(:group) }
  let(:agent_a)  { create(:agent, groups: [group]) }
  let(:agent_b)  { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }

  def rate(agent, service, resolution)
    ticket = create(:ticket, group:, customer:, owner: agent, state:)
    create(:ticket_satisfaction_rating, ticket:, customer:, score_service: service, score_resolution: resolution)
  end

  def rate_legacy(agent, service)
    ticket = create(:ticket, group:, customer:, owner: agent, state:)
    create(:ticket_satisfaction_rating, :legacy, ticket:, customer:, score_service: service)
  end

  before do
    rate(agent_a, 5, 4)
    rate(agent_a, 3, 2)
    rate_legacy(agent_b, 4)
  end

  it 'computes overall count and per-dimension count, average and distribution' do
    result = described_class.new({}).execute
    expect(result[:overall][:count]).to eq(3)

    expect(result[:overall][:service][:count]).to eq(3)
    expect(result[:overall][:service][:average]).to eq(4.0)
    expect(result[:overall][:service][:distribution]).to include(3 => 1, 4 => 1, 5 => 1)

    # a avaliação legada não tem nota de resolução — não conta nessa dimensão
    expect(result[:overall][:resolution][:count]).to eq(2)
    expect(result[:overall][:resolution][:average]).to eq(3.0)
    expect(result[:overall][:resolution][:distribution]).to include(2 => 1, 4 => 1)
  end

  it 'breaks down by agent with per-dimension averages and the resolution sample size' do
    result = described_class.new({}).execute
    a = result[:by_agent].find { |row| row[:agent_id] == agent_a.id }
    expect(a[:count]).to eq(2)
    expect(a[:count_resolution]).to eq(2)
    expect(a[:average_service]).to eq(4.0)
    expect(a[:average_resolution]).to eq(3.0)

    b = result[:by_agent].find { |row| row[:agent_id] == agent_b.id }
    expect(b[:count]).to eq(1)
    expect(b[:count_resolution]).to eq(0)
    expect(b[:average_service]).to eq(4.0)
    expect(b[:average_resolution]).to be_nil
  end

  it 'computes the overall response rate from the finalized cohort' do
    create(:ticket, group:, customer:, owner: agent_a, state:) # finalized, unrated
    result = described_class.new({}).execute
    expect(result[:overall][:response_rate]).to eq(0.75) # 3 rated of 4 finalized
  end

  it 'filters by agent_id' do
    result = described_class.new({ agent_id: agent_b.id }).execute
    expect(result[:overall][:count]).to eq(1)
    expect(result[:by_agent].size).to eq(1)
  end
end
```

- [ ] **Step 4.2: Rodar e confirmar falha**

Run: `bundle exec rspec spec/services/service/csat/stats_spec.rb`
Expected: FAIL — shape antigo (`average`/`distribution` no topo, `pluck(:score)`).

- [ ] **Step 4.3: Reescrever o service**

Substituir o conteúdo inteiro de `app/services/service/csat/stats.rb` por:

```ruby
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Service::Csat::Stats
  def initialize(params)
    @params = params
  end

  def execute
    rel = filtered_scope
    {
      overall:  overall(rel),
      by_agent: by_agent(rel),
    }
  end

  private

  def filtered_scope
    rel = Ticket::SatisfactionRating.all
    rel = rel.where(agent_id: @params[:agent_id]) if @params[:agent_id].present?
    rel = rel.where(group_id: @params[:group_id]) if @params[:group_id].present?
    rel = rel.where(created_at: Time.zone.parse(@params[:date_from])..) if @params[:date_from].present?
    rel = rel.where(created_at: ..Time.zone.parse(@params[:date_to]))   if @params[:date_to].present?
    rel
  end

  def overall(rel)
    {
      count:         rel.count,
      response_rate: response_rate,
      service:       dimension(rel, :score_service),
      resolution:    dimension(rel, :score_resolution),
    }
  end

  # Agregados de uma dimensão. Avaliações legadas têm score_resolution NULL e
  # ficam fora do count/média/distribuição daquela dimensão.
  def dimension(rel, column)
    scores = rel.where.not(column => nil).pluck(column)
    {
      count:        scores.size,
      average:      scores.empty? ? nil : (scores.sum.to_f / scores.size).round(2),
      distribution: (1..5).index_with { |s| scores.count(s) },
    }
  end

  def by_agent(rel)
    rel.group(:agent_id)
       .pluck(:agent_id, Arel.sql('COUNT(*)'), Arel.sql('COUNT(score_resolution)'), Arel.sql('AVG(score_service)'), Arel.sql('AVG(score_resolution)'))
       .map do |agent_id, count, count_resolution, avg_service, avg_resolution|
         {
           agent_id:,
           agent:              User.find_by(id: agent_id)&.fullname,
           count:              count,
           count_resolution:   count_resolution,
           average_service:    avg_service&.to_f&.round(2),
           average_resolution: avg_resolution&.to_f&.round(2),
         }
       end
  end

  # Taxa de Resposta (overall): of tickets finalized in the window (close_at), how many have a rating.
  def response_rate
    cohort = finalized_cohort
    total  = cohort.count
    return nil if total.zero?

    rated = cohort.where(id: Ticket::SatisfactionRating.select(:ticket_id)).count
    (rated.to_f / total).round(2)
  end

  def finalized_cohort
    rel = Ticket.where.not(close_at: nil)
    rel = rel.where(close_at: Time.zone.parse(@params[:date_from])..) if @params[:date_from].present?
    rel = rel.where(close_at: ..Time.zone.parse(@params[:date_to]))   if @params[:date_to].present?
    rel = rel.where(group_id: @params[:group_id]) if @params[:group_id].present?
    rel = rel.where(owner_id: @params[:agent_id]) if @params[:agent_id].present?
    rel
  end
end
```

(`AVG(...)` e `COUNT(coluna)` em SQL ignoram NULL — por isso `average_resolution` de um atendente só-legado vem `nil` e `count_resolution` é o n real da média de resolução. `count` já é o n do serviço, pois `score_service` é NOT NULL.)

- [ ] **Step 4.4: Rodar o service spec até verde**

Run: `bundle exec rspec spec/services/service/csat/stats_spec.rb`
Expected: PASS.

- [ ] **Step 4.5: Atualizar o request spec do stats**

Em `spec/requests/csat_stats_spec.rb`:

- No `before`, trocar `create(:ticket_satisfaction_rating, ticket:, customer:, score: 5)` por
  `create(:ticket_satisfaction_rating, ticket:, customer:, score_service: 5, score_resolution: 4)`.
- No teste `'returns overall + by_agent to an admin'`, após a linha do `count`, adicionar:

```ruby
    expect(json_response['overall']['service']['average']).to eq(5.0)
    expect(json_response['overall']['resolution']['average']).to eq(4.0)
    expect(json_response['by_agent'].first['average_service']).to eq(5.0)
    expect(json_response['by_agent'].first['count_resolution']).to eq(1)
```

- [ ] **Step 4.6: Rodar até verde**

Run: `bundle exec rspec spec/requests/csat_stats_spec.rb`
Expected: PASS.

**SEM COMMIT.**

---

### Task 5: Embed no payload do ticket (GET /tickets)

**Files:**
- Modify: `app/models/ticket/assets.rb`
- Test: `spec/requests/ticket_satisfaction_embed_spec.rb`

- [ ] **Step 5.1: Atualizar o embed spec (fica vermelho)**

Em `spec/requests/ticket_satisfaction_embed_spec.rb`:

- No contexto `'when the ticket has a rating'`, trocar o `before` por:

```ruby
    before { create(:ticket_satisfaction_rating, ticket:, customer:, score_service: 4, score_resolution: 5, comment: 'Ótimo') }
```

- No teste do GET expandido, trocar o bloco `expect(sat).to include(...)` por:

```ruby
      expect(sat).to include(
        'score_service'    => 4,
        'score_resolution' => 5,
        'comment'          => 'Ótimo',
        'agent_id'         => agent.id,
        'agent_name'       => agent.fullname,
        'group_id'         => group.id,
      )
```

- No teste do GET puro, trocar as duas asserções de `satisfaction` por:

```ruby
      expect(json_response.dig('satisfaction', 'score_service')).to eq(4)
      expect(json_response.dig('satisfaction', 'score_resolution')).to eq(5)
      expect(json_response.dig('satisfaction', 'agent_name')).to eq(agent.fullname)
```

- No teste da lista, trocar `expect(row.dig('satisfaction', 'score')).to eq(4)` por
  `expect(row.dig('satisfaction', 'score_service')).to eq(4)`.
- Adicionar um novo contexto no mesmo describe (depois do contexto `'when the ticket has a rating'`):

```ruby
  context 'when the ticket has a legacy rating (no resolution score)' do
    before { create(:ticket_satisfaction_rating, :legacy, ticket:, customer:, score_service: 3) }

    it 'returns score_resolution as null' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}", as: :json
      expect(json_response.dig('satisfaction', 'score_service')).to eq(3)
      expect(json_response['satisfaction']).to have_key('score_resolution')
      expect(json_response['satisfaction']['score_resolution']).to be_nil
    end
  end
```

- [ ] **Step 5.2: Rodar e confirmar falha**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_embed_spec.rb`
Expected: FAIL — payload ainda traz a chave `score`.

- [ ] **Step 5.3: Atualizar o payload**

Em `app/models/ticket/assets.rb`, no método `satisfaction_rating_payload`, trocar o hash de retorno:

```ruby
    {
      'score_service'    => rating.score_service,
      'score_resolution' => rating.score_resolution,
      'comment'          => rating.comment,
      'agent_id'         => rating.agent_id,
      'agent_name'       => rating.agent&.fullname,
      'group_id'         => rating.group_id,
      'created_at'       => rating.created_at,
    }
```

(o restante do método — `find_by` direto e comentário explicando — fica como está).

- [ ] **Step 5.4: Rodar até verde (embed + regressão do ratable)**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_embed_spec.rb spec/requests/ticket_satisfaction_ratable_spec.rb`
Expected: PASS.

**SEM COMMIT.**

---

### Task 6: UI clássica — modal com duas fileiras (resolução primeiro)

**Files:**
- Modify: `app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco`
- Modify: `app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee`
- Modify: `app/assets/stylesheets/zammad.scss` (bloco `.csat-modal`, ~linha 16331)

Sem teste automatizado para este modal (padrão da PR original); a verificação é o
`assets:precompile` + QA manual na Task 9.

- [ ] **Step 6.1: Atualizar o template**

Substituir o conteúdo inteiro de `app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco` por:

```eco
<!-- app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco -->
<div class="csat-modal">
  <div class="csat-modal__group">
    <p class="csat-modal__label" id="csat-label-resolution"><%- @T('How do you rate the resolution of your problem?') %></p>
    <div class="csat-modal__stars" role="group" aria-labelledby="csat-label-resolution">
      <% for star in [1, 2, 3, 4, 5]: %>
        <button type="button" class="js-csat-star csat-modal__star" data-dimension="resolution" data-value="<%= star %>" aria-label="<%- @T('%s stars', star) %>">★</button>
      <% end %>
    </div>
  </div>
  <div class="csat-modal__group">
    <p class="csat-modal__label" id="csat-label-service"><%- @T('How do you rate the service?') %></p>
    <div class="csat-modal__stars" role="group" aria-labelledby="csat-label-service">
      <% for star in [1, 2, 3, 4, 5]: %>
        <button type="button" class="js-csat-star csat-modal__star" data-dimension="service" data-value="<%= star %>" aria-label="<%- @T('%s stars', star) %>">★</button>
      <% end %>
    </div>
  </div>
  <% if @commentMode isnt 'off': %>
    <label class="csat-modal__comment-label" for="csat-comment"><%- @T('Comment') %></label>
    <textarea id="csat-comment" class="js-csat-comment csat-modal__comment" rows="4"></textarea>
  <% end %>
  <p class="js-csat-error csat-modal__error"></p>
</div>
```

- [ ] **Step 6.2: Atualizar o controller Coffee**

Em `app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee`:

No `constructor`, adicionar a inicialização do estado por dimensão:

```coffee
  constructor: ->
    super
    @ticketId = @ticket.id
    @scores   = {}
```

Substituir o método `selectStar` inteiro por:

```coffee
  selectStar: (e) =>
    e.preventDefault()
    $star     = $(e.currentTarget)
    dimension = $star.attr('data-dimension')
    value     = parseInt($star.attr('data-value'), 10)
    @scores[dimension] = value
    @$(".js-csat-star[data-dimension='#{dimension}']").each ->
      starValue = parseInt($(@).attr('data-value'), 10)
      $(@).toggleClass('is-selected', starValue <= value)
    @$('.js-csat-error').text('')
```

No `onSubmit`, substituir o bloco de validação + request:

```coffee
  onSubmit: =>
    commentMode = App.Config.get('csat_comment') or 'optional'
    comment     = @$('.js-csat-comment').val() or ''

    if !@scores.resolution or !@scores.service
      @$('.js-csat-error').text(App.i18n.translateContent('Please rate both fields.'))
      return
    if commentMode is 'required' and not comment.trim()
      @$('.js-csat-error').text(App.i18n.translateContent('Please add a comment.'))
      return

    App.Ajax.request(
      id:          "csat-#{@ticketId}"
      type:        'POST'
      url:         "#{@apiPath}/csat/ratings"
      data:        JSON.stringify(ticket_id: @ticketId, score_service: @scores.service, score_resolution: @scores.resolution, comment: comment)
      processData: true
      success: (data) =>
        @submitted = true
        @notify(type: 'success', msg: App.i18n.translateContent('Thanks for your feedback!'))
        @close()
      error: (xhr) =>
        @$('.js-csat-error').text(App.i18n.translateContent('Could not save your rating.'))
    )
```

(`onCancel`/`onClose`/`markDismissed` ficam como estão.)

- [ ] **Step 6.3: Espaçamento entre os grupos no SCSS**

Em `app/assets/stylesheets/zammad.scss`, dentro do bloco `.csat-modal` (~linha 16331),
adicionar logo após o bloco `&__label { ... }`:

```scss
  &__group + &__group {
    margin-top: 8px;
  }
```

- [ ] **Step 6.4: Verificação de sintaxe (gate do deploy)**

Run: `bundle exec rake assets:precompile`
Expected: termina sem erro (é este build que roda no Coolify; erro de Coffee/SCSS quebra o deploy).
Nota: pode demorar alguns minutos; é a única verificação automatizada da UI legacy.

**SEM COMMIT.**

---

### Task 7: i18n (.pot + pt-BR)

**Files:**
- Modify: `i18n/zammad.pot` (~linha 21951)
- Modify: `i18n/zammad.pt-br.po` (~linha 27828)

- [ ] **Step 7.1: Atualizar o catálogo-fonte**

Em `i18n/zammad.pot`, substituir o bloco:

```po
msgid "How was your support?"
msgstr ""
```

por:

```po
msgid "How do you rate the resolution of your problem?"
msgstr ""

msgid "How do you rate the service?"
msgstr ""
```

E substituir o bloco:

```po
msgid "Please select a rating."
msgstr ""
```

por:

```po
msgid "Please rate both fields."
msgstr ""
```

- [ ] **Step 7.2: Atualizar o pt-BR**

Em `i18n/zammad.pt-br.po`, substituir o bloco:

```po
msgid "How was your support?"
msgstr "Como foi o seu atendimento?"
```

por:

```po
msgid "How do you rate the resolution of your problem?"
msgstr "Como você avalia a resolução do problema?"

msgid "How do you rate the service?"
msgstr "Como você avalia o atendimento?"
```

E substituir o bloco:

```po
msgid "Please select a rating."
msgstr "Selecione uma nota."
```

por:

```po
msgid "Please rate both fields."
msgstr "Selecione uma nota nos dois campos."
```

- [ ] **Step 7.3: Conferir que nenhum uso órfão sobrou**

Run: `grep -rn "How was your support\|Please select a rating" app/ i18n/`
Expected: nenhuma ocorrência.

**SEM COMMIT.**

---

### Task 8: Docs (CONTEXT.md, ADR 0003) — pré-aplicada na sessão de grill (2026-07-06)

> Os dois arquivos **já foram escritos** durante a sessão de grill que revisou este plano e
> ficam uncommitted até a Task 9. Diferença vs. o texto abaixo: a entrada "Nota de Atendimento"
> ganhou a frase que desambigua "atendimento" não-qualificado (decisão da sessão), e a descrição
> do topo diz "a avaliação é creditada" (não mais "a nota"). Executar esta task = só verificar:
> `grep -n "Nota de Resolução\|Nota de Atendimento" docs/csat/CONTEXT.md && ls docs/csat/adr/`
> → os dois termos no glossário e o ADR 0003 listado ao lado de 0001/0002.

**Files:**
- Modify: `docs/csat/CONTEXT.md` (já feito)
- Create: `docs/csat/adr/0003-nota-unica-vira-nota-de-atendimento.md` (já feito)

- [x] **Step 8.1: Atualizar o glossário** (feito na sessão de grill)

Em `docs/csat/CONTEXT.md`:

- Na descrição do topo, trocar `o Cliente avalia o atendimento (1–5 estrelas) num popup` por
  `o Cliente avalia a resolução do problema e o atendimento (duas notas 1–5) num popup`.
- Substituir a definição de **Avaliação de Satisfação (CSAT)** por:

```md
**Avaliação de Satisfação (CSAT)**:
O par de notas 1–5 — Nota de Resolução e Nota de Atendimento — (com comentário opcional) que um Cliente dá a um atendimento finalizado. Uma por ticket, gravada uma única vez. No código: `Ticket::SatisfactionRating`.
_Evitar_: pesquisa, survey, feedback, NPS, "rating" genérico
```

- Adicionar logo após essa definição os dois termos novos:

```md
**Nota de Resolução**:
A nota 1–5 que o Cliente dá à resolução do problema, primeira pergunta do popup. Nula nas Avaliações registradas antes da dimensão existir. No código: `score_resolution`.
_Evitar_: nota do problema, score de solução

**Nota de Atendimento**:
A nota 1–5 que o Cliente dá ao atendimento em si — *como foi atendido*, em contraste com a resolução —, segunda pergunta do popup. "Atendimento" sem qualificador segue sendo a experiência toda do ticket finalizado (sentido do título do popup); as Avaliações antigas (nota única) são Notas de Atendimento (ver ADR 0003). No código: `score_service`.
_Evitar_: score (ambíguo), nota geral
```

- [x] **Step 8.2: Criar o ADR 0003** (feito na sessão de grill)

Criar `docs/csat/adr/0003-nota-unica-vira-nota-de-atendimento.md`:

```md
---
status: accepted
---

# A nota única histórica torna-se Nota de Atendimento

Ao dividir a Avaliação em duas dimensões (`score_service` + `score_resolution`), a coluna `score`
já registrada em produção foi **renomeada para `score_service`** (Nota de Atendimento): o popup
sempre perguntou "Como foi o seu atendimento?", então essa é a semântica que o dado sempre teve.
A Nota de Resolução fica `NULL` nas Avaliações antigas — o Cliente nunca a deu — e por isso as
contagens por dimensão diferem nas estatísticas (médias ignoram `NULL`).

## Alternativas rejeitadas

- **Histórico como dimensão legada separada**: quebraria a comparabilidade das médias de
  atendimento sem ganho — o dado antigo já é atendimento.
- **Copiar a nota antiga para as duas dimensões**: inventaria uma Nota de Resolução que o
  Cliente nunca deu.
- **Manter `score` + adicionar só `score_resolution`**: evitaria o rename, mas deixaria uma
  assimetria permanente ("score de quê?") no banco e na API. O rename foi feito enquanto não
  há consumidor externo (dashboard admin ainda não existe; nenhuma integração lê esses campos).
```

**SEM COMMIT.**

---

### Task 9: Verificação final, QA manual e commit único

**Files:**
- Modify: `.claude/NEWBYTE_WORKFLOW.md` (changelog)
- Commit: tudo da feature + `docs/superpowers/specs/2026-07-06-csat-two-scores-design.md` + este plano

- [ ] **Step 9.1: Suite CSAT completa**

Run:

```bash
bundle exec rspec \
  spec/models/ticket/satisfaction_rating_spec.rb \
  spec/policies/ticket/satisfaction_rating_policy_spec.rb \
  spec/requests/csat_ratings_spec.rb \
  spec/requests/csat_surveys_spec.rb \
  spec/requests/csat_stats_spec.rb \
  spec/requests/ticket_satisfaction_embed_spec.rb \
  spec/requests/ticket_satisfaction_ratable_spec.rb \
  spec/services/service/csat/stats_spec.rb \
  spec/db/seeds/csat_spec.rb \
  spec/db/migrate/add_csat_permissions_and_settings_spec.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 9.2: Rubocop nos arquivos Ruby alterados**

Run:

```bash
bundle exec rubocop \
  db/migrate/20260706000001_split_csat_score_into_service_and_resolution.rb \
  app/models/ticket/satisfaction_rating.rb \
  app/controllers/csat_ratings_controller.rb \
  app/controllers/csat_surveys_controller.rb \
  app/services/service/csat/stats.rb \
  app/models/ticket/assets.rb \
  spec/factories/ticket/satisfaction_rating.rb \
  spec/models/ticket/satisfaction_rating_spec.rb \
  spec/requests/csat_ratings_spec.rb \
  spec/requests/csat_surveys_spec.rb \
  spec/requests/csat_stats_spec.rb \
  spec/requests/ticket_satisfaction_embed_spec.rb \
  spec/services/service/csat/stats_spec.rb
```

Expected: no offenses (corrigir o que aparecer antes de seguir).

- [ ] **Step 9.3: QA manual na UI clássica** (usar o skill `run`/`verify` do projeto; servidor via `Procfile.dev`)

Checklist:
1. Como atendente: criar ticket para um cliente e fechá-lo.
2. Como o cliente: abrir o ticket fechado → popup aparece com **resolução primeiro, atendimento depois**.
3. Enviar sem uma das notas → erro "Selecione uma nota nos dois campos."
4. Selecionar as duas + comentário → sucesso "Obrigado pela sua avaliação!"; reabrir o ticket → popup não volta.
5. `GET /api/v1/tickets/<id>` (token admin) → `satisfaction.score_service` + `score_resolution` preenchidos.
6. Conferir uma avaliação antiga (pré-migração) no banco → `score_service` preservado, `score_resolution` NULL, e `/csat/stats` com counts por dimensão coerentes.
7. Testar em Chromium e WebKit/Safari (estrelas são texto — sem SVG novo).

- [ ] **Step 9.4: Changelog do workflow**

Adicionar ao final de `.claude/NEWBYTE_WORKFLOW.md` (seção Changelog), preenchendo PR/tag no momento do merge:

```md
### 2026-07-06 - PR #<n> (tag nb.v<x>)

**Branch**: `feat/csat-two-scores`

Alteracoes:
- **CSAT em duas dimensões**: nota única vira Nota de Atendimento (`score` renomeado
  para `score_service`, ADR 0003) + nova Nota de Resolução (`score_resolution`, NULL
  nas avaliações antigas). Popup com duas fileiras de estrelas (resolução primeiro),
  ambas obrigatórias. POST/surveys/stats/embed do ticket expõem o par; stats com
  bloco por dimensão (médias ignoram NULL; `count_resolution` por atendente).
  Sem alias para o param antigo `score`.
```

- [ ] **Step 9.5: Commit único da feature**

Conferir com `git status` que entram: migração, modelo, controllers, service, assets.rb,
eco/coffee/scss, i18n, specs, factory, docs/csat (CONTEXT.md + ADR 0003),
docs/superpowers/specs + plans desta feature e o changelog do workflow. **Não** adicionar
`.devcontainer/default/devcontainer-lock.json`, `skills-lock.json`, `.claude/skills/` nem
qualquer `.env` (regras do NEWBYTE_WORKFLOW.md — o `.claude/NEWBYTE_WORKFLOW.md` em si entra,
pois o changelog faz parte da entrega).

```bash
git add \
  db/migrate/20260706000001_split_csat_score_into_service_and_resolution.rb \
  app/models/ticket/satisfaction_rating.rb \
  app/controllers/csat_ratings_controller.rb \
  app/controllers/csat_surveys_controller.rb \
  app/services/service/csat/stats.rb \
  app/models/ticket/assets.rb \
  app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco \
  app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee \
  app/assets/stylesheets/zammad.scss \
  i18n/zammad.pot i18n/zammad.pt-br.po \
  spec/factories/ticket/satisfaction_rating.rb \
  spec/models/ticket/satisfaction_rating_spec.rb \
  spec/requests/csat_ratings_spec.rb \
  spec/requests/csat_surveys_spec.rb \
  spec/requests/csat_stats_spec.rb \
  spec/requests/ticket_satisfaction_embed_spec.rb \
  spec/services/service/csat/stats_spec.rb \
  docs/csat/CONTEXT.md \
  docs/csat/adr/0003-nota-unica-vira-nota-de-atendimento.md \
  docs/superpowers/specs/2026-07-06-csat-two-scores-design.md \
  docs/superpowers/plans/2026-07-06-csat-two-scores.md \
  .claude/NEWBYTE_WORKFLOW.md

git commit -m "$(cat <<'EOF'
feat(csat): duas dimensões de avaliação — resolução e atendimento

Divide a nota única do CSAT em duas notas 1–5: Nota de Resolução ("Como você
avalia a resolução do problema?") e Nota de Atendimento ("Como você avalia o
atendimento?") — nessa ordem no popup. A avaliação segue sendo um registro
único, write-once, por (ticket, cliente).

- Banco: rename score → score_service + nova coluna score_resolution (NULL
  nas avaliações antigas — o dado histórico vira Nota de Atendimento, ADR 0003).
- Modelo: ambas obrigatórias (resolução com on: :create para preservar linhas
  legadas), attr_readonly cobre os dois scores.
- API: POST /csat/ratings exige as duas; surveys/stats/embed no ticket expõem
  score_service/score_resolution (stats com bloco por dimensão; AVG ignora
  NULL; by_agent com count_resolution, o n da média de resolução). Sem alias
  para o param antigo `score` — aba pré-deploy toma 422; no pior caso perde-se
  essa avaliação (aceito).
- UI clássica: modal com duas fileiras de estrelas (resolução primeiro),
  validação única, i18n pt-BR.
- Docs: spec + plano em docs/superpowers/, CONTEXT.md, ADR 0003, changelog.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

Expected: um único commit na `feat/csat-two-scores`. Push + PR contra `newbyte-stable` e
tag `nb.v{next}` são decididos com o usuário depois (fluxo do NEWBYTE_WORKFLOW.md — perguntar a
versão da tag antes de criar).
