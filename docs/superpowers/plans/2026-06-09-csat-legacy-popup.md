# CSAT — Popup do Cliente na UI Antiga (legacy) — Plano de Implementação

> **Para workers agênticos:** SUB-SKILL OBRIGATÓRIA: usar superpowers:subagent-driven-development (recomendado) ou superpowers:executing-plans pra executar tarefa-a-tarefa. Steps usam checkbox (`- [ ]`).

**Goal:** Quando o Cliente abre (ou está olhando enquanto o atendente finaliza) um ticket `closed` ainda não avaliado, mostrar na **UI clássica** (Spine/CoffeeScript + REST) um popup pra dar nota 1–5 + comentário opcional, gravando uma única vez, imutável, creditada ao dono do ticket.

**Architecture:** Reaproveita o backend existente (modelo `Ticket::SatisfactionRating`, permissões, settings, policy, API REST de leitura). Adiciona: (1) `Ticket::SatisfactionRating.ratable?` como fonte única de verdade (envolve a policy); (2) campo computado `satisfaction_ratable` no payload REST do ticket via `filter_unauthorized_attributes`; (3) endpoint REST `POST /api/v1/csat/ratings`; (4) modal Spine `App.TicketZoomCsatModal` + template + SCSS; (5) gatilho no `ticket_zoom.coffee` (abertura + ao vivo, via re-fetch REST). Spec: `docs/superpowers/specs/2026-06-09-csat-legacy-popup-design.md`. ADR: `docs/csat/adr/0001-csat-na-ui-classica.md`.

**Tech Stack:** Ruby on Rails, Pundit, RSpec/FactoryBot (backend); Spine.js/CoffeeScript, `.jst.eco`, SCSS, Sprockets, REST (legacy frontend).

**Nomes canônicos (usar EXATAMENTE):**
- Método: `Ticket::SatisfactionRating.ratable?(ticket:, user:)` (boolean)
- Atributo REST exposto no ticket: `satisfaction_ratable`
- Endpoint: `POST /api/v1/csat/ratings` → `CsatRatingsController#create`; controller-policy `Controllers::CsatRatingsControllerPolicy`
- Legacy: controller `App.TicketZoomCsatModal` (`app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee`); template `app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco`; método de gatilho `TicketZoom#triggerSatisfactionRating`; chave de dispensa `csat_dismissed_ticket_<id>` (App.LocalStorage)

---

## Task 0: Baseline

**Files:** nenhum (verificação).

- [ ] **Step 1: Confirmar branch + backend verde + revert aplicado**

Run: `git rev-parse --abbrev-ref HEAD` → Esperado: `feat/csat`
Run: `find app/frontend -not -path '*/node_modules/*' \( -iname '*satisfaction*' -o -ipath '*TicketSatisfaction*' \)` → Esperado: vazio (nenhum resíduo da UI Vue).
Run:
```bash
bundle exec rspec spec/models/ticket/satisfaction_rating_spec.rb \
  spec/policies/ticket/satisfaction_rating_policy_spec.rb \
  spec/db/seeds/csat_spec.rb spec/requests/csat_surveys_spec.rb spec/requests/csat_stats_spec.rb
```
Esperado: tudo PASS (backend reaproveitado íntegro).

---

## Task 1: `Ticket::SatisfactionRating.ratable?` (fonte única de verdade)

**Files:**
- Modify: `app/models/ticket/satisfaction_rating.rb`
- Test: `spec/models/ticket/satisfaction_rating_spec.rb` (append)

- [ ] **Step 1: Escrever o spec que falha**

Adicionar ao final do `RSpec.describe Ticket::SatisfactionRating` em `spec/models/ticket/satisfaction_rating_spec.rb` (antes do `end` final do describe):

```ruby
  describe '.ratable?' do
    let(:group)    { create(:group) }
    let(:agent)    { create(:agent, groups: [group]) }
    let(:customer) { create(:customer) }
    let(:state)    { Ticket::State.find_by(name: 'closed') }
    let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

    before { Setting.set('csat_integration', true) }

    it 'is true for the customer of a closed, unrated ticket' do
      expect(described_class.ratable?(ticket:, user: customer)).to be(true)
    end

    it 'is false when CSAT is disabled' do
      Setting.set('csat_integration', false)
      expect(described_class.ratable?(ticket:, user: customer)).to be(false)
    end

    it 'is false for a non-customer' do
      expect(described_class.ratable?(ticket:, user: agent)).to be(false)
    end

    it 'is false when the ticket is not finalized' do
      ticket.update!(state: Ticket::State.find_by(name: 'open'))
      expect(described_class.ratable?(ticket:, user: customer)).to be(false)
    end

    it 'is false when already rated' do
      create(:ticket_satisfaction_rating, ticket:, customer:)
      expect(described_class.ratable?(ticket:, user: customer)).to be(false)
    end

    it 'is false when user is nil' do
      expect(described_class.ratable?(ticket:, user: nil)).to be(false)
    end
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `bundle exec rspec spec/models/ticket/satisfaction_rating_spec.rb -e ".ratable?"`
Esperado: FAIL — `undefined method 'ratable?'`

- [ ] **Step 3: Implementar o método**

Em `app/models/ticket/satisfaction_rating.rb`, adicionar logo após a linha `before_create :snapshot_agent_and_group` (antes do `private`):

```ruby
  # True if `user` may rate `ticket` right now (CSAT on, user is the ticket
  # customer, ticket finalized, no prior rating). Single source of truth: wraps
  # the policy so this boolean and the create authorization never drift.
  def self.ratable?(ticket:, user:)
    return false if user.blank?

    Ticket::SatisfactionRatingPolicy.new(user, new(ticket:, customer: user)).create? == true
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `bundle exec rspec spec/models/ticket/satisfaction_rating_spec.rb`
Esperado: PASS (todos).

- [ ] **Step 5: Commit**

```bash
git add app/models/ticket/satisfaction_rating.rb spec/models/ticket/satisfaction_rating_spec.rb
git commit -m "feat(csat): add Ticket::SatisfactionRating.ratable? (single source of truth)"
```

---

## Task 2: Expor `satisfaction_ratable` no payload REST do ticket

**Files:**
- Modify: `app/models/ticket/assets.rb`
- Test: `spec/requests/ticket_satisfaction_ratable_spec.rb` (criar)

> Contexto: `attributes_with_association_ids`/`_names` chamam `filter_unauthorized_attributes(attributes)` no fim (`app/models/application_model/can_associations.rb:179,253`). `Ticket::Assets#assets` usa `attributes_with_association_ids`. Logo, sobrescrever `filter_unauthorized_attributes` em `Ticket::Assets` injeta o campo em todos os caminhos REST (`?all=true`, `?expand`, default). `User::Assets` faz exatamente esse padrão.

- [ ] **Step 1: Escrever o request spec que falha**

```ruby
# spec/requests/ticket_satisfaction_ratable_spec.rb
require 'rails_helper'

RSpec.describe 'Ticket payload satisfaction_ratable', type: :request do
  let(:group)    { create(:group) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

  before { Setting.set('csat_integration', true) }

  def ticket_asset(response_body, ticket_id)
    JSON.parse(response_body).dig('assets', 'Ticket', ticket_id.to_s)
  end

  it 'exposes satisfaction_ratable=true to the ticket customer when ratable' do
    authenticated_as(customer)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(response).to have_http_status(:ok)
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).to be(true)
  end

  it 'is not true for an agent viewing the same ticket' do
    authenticated_as(agent)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).not_to be(true)
  end

  it 'is false for the customer when CSAT is disabled' do
    Setting.set('csat_integration', false)
    authenticated_as(customer)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).to be_falsey
  end

  it 'is false for the customer once a rating exists' do
    create(:ticket_satisfaction_rating, ticket:, customer:)
    authenticated_as(customer)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).to be(false)
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_ratable_spec.rb`
Esperado: FAIL (chave `satisfaction_ratable` ausente).

- [ ] **Step 3: Implementar o override**

Em `app/models/ticket/assets.rb`, dentro do `module Ticket::Assets`, adicionar este método (ex.: logo após `def authorized_asset?` ... `end`, antes do `end` do module):

```ruby
  def filter_unauthorized_attributes(attributes)
    attributes = super

    user_id = UserInfo.current_user_id
    if user_id.present? && Setting.get('csat_integration')
      user = User.lookup(id: user_id)
      attributes['satisfaction_ratable'] = user.present? && Ticket::SatisfactionRating.ratable?(ticket: self, user:)
    end

    attributes
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `bundle exec rspec spec/requests/ticket_satisfaction_ratable_spec.rb`
Esperado: PASS (todos).

- [ ] **Step 5: Commit**

```bash
git add app/models/ticket/assets.rb spec/requests/ticket_satisfaction_ratable_spec.rb
git commit -m "feat(csat): expose satisfaction_ratable on the ticket REST payload"
```

---

## Task 3: Endpoint REST `POST /api/v1/csat/ratings`

**Files:**
- Modify: `config/routes/csat.rb`
- Create: `app/controllers/csat_ratings_controller.rb`
- Create: `app/policies/controllers/csat_ratings_controller_policy.rb`
- Test: `spec/requests/csat_ratings_spec.rb`

> Auth: `prepend_before_action :authentication_check` (NÃO `authenticate_and_authorize!`), pra o Cliente (sem `csat.read`) poder criar. O gating real é no registro via `authorize!(rating, :create?)` (policy `Ticket::SatisfactionRatingPolicy`). A controller-policy com `default_permit!('admin')` é o padrão "dormente" (igual ao `TicketArticlesController`).

- [ ] **Step 1: Escrever o request spec que falha**

```ruby
# spec/requests/csat_ratings_spec.rb
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
      post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score: 4, comment: 'Ótimo' }, as: :json
    end.to change(Ticket::SatisfactionRating, :count).by(1)
    expect(response).to have_http_status(:created)
    rating = Ticket::SatisfactionRating.last
    expect(rating.score).to eq(4)
    expect(rating.agent_id).to eq(agent.id)
  end

  it 'forbids a non-customer (agent)' do
    authenticated_as(agent)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'forbids rating an open ticket' do
    ticket.update!(state: Ticket::State.find_by(name: 'open'))
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'forbids a second rating' do
    create(:ticket_satisfaction_rating, ticket:, customer:)
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'drops the comment when csat_comment is off' do
    Setting.set('csat_comment', 'off')
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score: 5, comment: 'x' }, as: :json
    expect(response).to have_http_status(:created)
    expect(Ticket::SatisfactionRating.last.comment).to be_nil
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `bundle exec rspec spec/requests/csat_ratings_spec.rb`
Esperado: FAIL (rota/controller ausente).

- [ ] **Step 3: Adicionar a rota**

Em `config/routes/csat.rb`, dentro do bloco `draw`, adicionar abaixo das rotas existentes:

```ruby
  match api_path + '/csat/ratings', to: 'csat_ratings#create', via: :post
```

- [ ] **Step 4: Adicionar a controller-policy**

```ruby
# app/policies/controllers/csat_ratings_controller_policy.rb
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Controllers::CsatRatingsControllerPolicy < Controllers::ApplicationControllerPolicy
  default_permit!('admin')
end
```

- [ ] **Step 5: Adicionar o controller**

```ruby
# app/controllers/csat_ratings_controller.rb
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class CsatRatingsController < ApplicationController
  prepend_before_action :authentication_check

  # POST /api/v1/csat/ratings
  def create
    rating = ::Ticket::SatisfactionRating.new(
      ticket:   Ticket.find(params[:ticket_id]),
      customer: current_user,
      score:    params[:score],
      comment:  comment_value(params[:comment]),
    )

    authorize!(rating, :create?)
    rating.save!

    render json: serialize(rating), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def comment_value(comment)
    return if Setting.get('csat_comment') == 'off'

    comment
  end

  def serialize(rating)
    {
      id:         rating.id,
      ticket_id:  rating.ticket_id,
      score:      rating.score,
      comment:    rating.comment,
      created_at: rating.created_at,
    }
  end
end
```

- [ ] **Step 6: Rodar e ver passar**

Run: `bundle exec rspec spec/requests/csat_ratings_spec.rb`
Esperado: PASS (todos).

- [ ] **Step 7: Commit**

```bash
git add config/routes/csat.rb app/controllers/csat_ratings_controller.rb app/policies/controllers/csat_ratings_controller_policy.rb spec/requests/csat_ratings_spec.rb
git commit -m "feat(csat): add POST /api/v1/csat/ratings (customer-created, record-authorized)"
```

---

## Task 4: Modal legacy (controller + template + SCSS)

**Files:**
- Create: `app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee`
- Create: `app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco`
- Modify: `app/assets/stylesheets/zammad.scss`

> Sem teste unitário (o app legacy não tem infra de teste de controller; cobertura via QA manual na Task 6 + as request specs do backend). `.coffee`/`.jst.eco` novos são auto-incluídos pelo Sprockets (`require_tree`). Verificação aqui = `assets:precompile` compila.

- [ ] **Step 1: Criar o template**

```eco
<!-- app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco -->
<div class="csat-modal">
  <p class="csat-modal__label"><%- @T('How was your support?') %></p>
  <div class="csat-modal__stars">
    <% for star in [1, 2, 3, 4, 5]: %>
      <button type="button" class="js-csat-star csat-modal__star" data-value="<%= star %>" aria-label="<%- @T('%s stars', star) %>">★</button>
    <% end %>
  </div>
  <% if @commentMode isnt 'off': %>
    <label class="csat-modal__comment-label" for="csat-comment"><%- @T('Comment') %></label>
    <textarea id="csat-comment" class="js-csat-comment csat-modal__comment" rows="4"></textarea>
  <% end %>
  <p class="js-csat-error csat-modal__error"></p>
</div>
```

- [ ] **Step 2: Criar o controller do modal**

```coffee
# app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee
class App.TicketZoomCsatModal extends App.ControllerModal
  backdrop:     'static'   # clicar fora não fecha (evita dispensa acidental)
  buttonClose:  true
  buttonCancel: __('Not now')
  buttonSubmit: __('Submit')
  head:         __('Rate this ticket')
  small:        true

  events:
    'click .js-csat-star': 'selectStar'

  constructor: ->
    super
    @ticketId = @ticket.id

  content: ->
    App.view('ticket_zoom/csat_modal')(
      commentMode: App.Config.get('csat_comment') or 'optional'
    )

  selectStar: (e) =>
    e.preventDefault()
    @score = parseInt($(e.currentTarget).attr('data-value'), 10)
    score = @score
    @$('.js-csat-star').each ->
      value = parseInt($(@).attr('data-value'), 10)
      $(@).toggleClass('is-selected', value <= score)
    @$('.js-csat-error').text('')

  onSubmit: =>
    commentMode = App.Config.get('csat_comment') or 'optional'
    comment     = @$('.js-csat-comment').val() or ''

    if !@score
      @$('.js-csat-error').text(App.i18n.translateContent('Please select a rating.'))
      return
    if commentMode is 'required' and not comment.trim()
      @$('.js-csat-error').text(App.i18n.translateContent('Please add a comment.'))
      return

    App.Ajax.request(
      id:          "csat-#{@ticketId}"
      type:        'POST'
      url:         "#{@apiPath}/csat/ratings"
      data:        JSON.stringify(ticket_id: @ticketId, score: @score, comment: comment)
      processData: true
      success: (data) =>
        @submitted = true
        @notify(type: 'success', msg: App.i18n.translateContent('Thanks for your feedback!'))
        @close()
      error: (xhr) =>
        @$('.js-csat-error').text(App.i18n.translateContent('Could not save your rating.'))
    )

  # Qualquer fechar-sem-enviar (X, Esc, "Agora não") conta como dispensa, pra que
  # atualizações ao vivo do ticket não reabram o popup.
  onCancel: => @markDismissed()
  onClose:  -> @markDismissed()

  markDismissed: =>
    return if @submitted
    # App.LocalStorage assinatura: set(key, value, user_id) — user_id truthy => chave
    # "personal::<id>::<key>" (escopo por usuário). Mesma assinatura no get (Task 5).
    App.LocalStorage.set("csat_dismissed_ticket_#{@ticketId}", true, App.User.current()?.id)
```

- [ ] **Step 3: Adicionar o SCSS (estrelas Safari-safe via texto ★)**

Acrescentar ao final de `app/assets/stylesheets/zammad.scss`:

```scss
.csat-modal {
  &__label { font-weight: 600; margin-bottom: 8px; }

  &__stars { display: flex; gap: 4px; margin-bottom: 12px; }

  &__star {
    background: none;
    border: 0;
    padding: 0 2px;
    font-size: 28px;
    line-height: 1;
    cursor: pointer;
    color: hsl(0, 0%, 80%);

    &:hover,
    &.is-selected { color: #f7b500; }
  }

  &__comment-label { display: block; margin: 8px 0 4px; }
  &__comment { width: 100%; }
  &__error { color: hsl(0, 70%, 50%); min-height: 1.2em; margin-top: 8px; }
}
```

- [ ] **Step 4: Verificar que os assets compilam (deploy guard)**

Run: `node_modules/.bin/coffeelint app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee` (se o coffeelint estiver disponível; senão pular)
Run: `RAILS_ENV=production SECRET_KEY_BASE=dummy bundle exec rake assets:precompile 2>&1 | tail -5`
Esperado: precompile conclui sem erro de CoffeeScript/SCSS. (Depois, opcional: `git checkout public/assets 2>/dev/null` / limpar `public/assets` se gerado localmente — não commitar artefatos de precompile.)

> Se `assets:precompile` for muito pesado no ambiente, a verificação mínima aceitável é: `node_modules/.bin/coffeelint <arquivo>` limpo + revisão de que o `.jst.eco`/SCSS estão sintaticamente válidos.

- [ ] **Step 5: Commit**

```bash
git add app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee \
        app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco \
        app/assets/stylesheets/zammad.scss
git commit -m "feat(csat): legacy customer rating popup modal (Spine) + styles"
```

---

## Task 5: Gatilho no `ticket_zoom.coffee` (abertura + ao vivo)

**Files:**
- Modify: `app/assets/javascripts/app/controllers/ticket_zoom.coffee`

> O `load()` roda na abertura e em cada atualização (push `Ticket:update` → `fetchMayBe → fetch()` = GET REST `?all=true` novo → `satisfaction_ratable` fresco em `@currentTicketRaw`). Vamos chamar o gatilho ao fim do `load()`.

- [ ] **Step 1: Chamar o gatilho no fim do `load()`**

Em `app/assets/javascripts/app/controllers/ticket_zoom.coffee`, no método `load()`, logo após a linha:
```coffee
    App.Event.trigger('ui::ticket::all::loaded', data)
```
adicionar:
```coffee
    @triggerSatisfactionRating()
```

- [ ] **Step 2: Definir o método de gatilho**

No mesmo arquivo, adicionar este método logo após o `load:` (antes de `meta:`):

```coffee
  triggerSatisfactionRating: =>
    return if !App.Config.get('csat_integration')
    return if !@currentTicketRaw or !@currentTicketRaw.satisfaction_ratable
    return if !@ticket or @ticket.currentView() isnt 'customer'
    return if @ticket.customer_id isnt App.User.current()?.id
    return if App.LocalStorage.get("csat_dismissed_ticket_#{@ticket_id}", App.User.current()?.id)
    return if @csatModalShown

    @csatModalShown = true
    new App.TicketZoomCsatModal(
      container: @el.closest('.content')
      ticket:    @ticket
    )
```

- [ ] **Step 3: Verificar compilação (deploy guard)**

Run: `node_modules/.bin/coffeelint app/assets/javascripts/app/controllers/ticket_zoom.coffee` (se disponível)
Esperado: sem erros nas linhas adicionadas.

- [ ] **Step 4: Commit**

```bash
git add app/assets/javascripts/app/controllers/ticket_zoom.coffee
git commit -m "feat(csat): trigger the rating popup on customer ticket open + live finalize"
```

---

## Task 6: i18n (pt-BR) + verificação completa + QA manual

**Files:**
- Modify: `i18n/zammad.pot`, `i18n/zammad.pt-br.po`

- [ ] **Step 1: Regenerar o catálogo fonte**

Run: `bundle exec rails generate zammad:translation_catalog`
Esperado: `i18n/zammad.pot` atualizado com as novas strings do CSAT (do `.coffee`/`.jst.eco` e das mensagens da policy).

- [ ] **Step 2: Adicionar traduções pt-BR (apenas msgids novos, sem duplicar)**

Run (script idempotente — só adiciona o que não existe):
```bash
python3 - <<'PY'
import io
po = "i18n/zammad.pt-br.po"
c = io.open(po, encoding="utf-8").read()
entries = [
    ("Rate this ticket", "Avalie este atendimento"),
    ("How was your support?", "Como foi o seu atendimento?"),
    ("Comment", "Comentário"),
    ("Submit", "Enviar"),
    ("Not now", "Agora não"),
    ("Thanks for your feedback!", "Obrigado pela sua avaliação!"),
    ("Please select a rating.", "Selecione uma nota."),
    ("Please add a comment.", "Adicione um comentário."),
    ("Could not save your rating.", "Não foi possível salvar sua avaliação."),
    ("%s stars", "%s estrelas"),
    ("CSAT is not enabled", "O CSAT não está ativado"),
    ("Only the ticket customer can rate", "Apenas o cliente do ticket pode avaliar"),
    ("Ticket is not finalized", "O ticket não está finalizado"),
    ("This ticket was already rated", "Este ticket já foi avaliado"),
]
def has(mid): return ('\nmsgid "%s"\n' % mid) in c or c.startswith('msgid "%s"\n' % mid)
new = [e for e in entries if not has(e[0])]
if new:
    if not c.endswith("\n"): c += "\n"
    c += "\n" + "\n".join('msgid "%s"\nmsgstr "%s"\n' % (m, t) for m, t in new)
    io.open(po, "w", encoding="utf-8").write(c)
print("ADICIONADOS:", [m for m, _ in new])
print("JÁ EXISTIAM:", [m for m, _ in entries if has(m)])
PY
```
Run (validar o catálogo): `msgfmt -c -o /dev/null i18n/zammad.pt-br.po`
Esperado: válido (sem erro), sem msgid duplicado.

- [ ] **Step 3: Suite completa do backend CSAT**

Run:
```bash
bundle exec rspec \
  spec/models/ticket/satisfaction_rating_spec.rb \
  spec/policies/ticket/satisfaction_rating_policy_spec.rb \
  spec/requests/ticket_satisfaction_ratable_spec.rb \
  spec/requests/csat_ratings_spec.rb \
  spec/requests/csat_surveys_spec.rb \
  spec/requests/csat_stats_spec.rb \
  spec/db/seeds/csat_spec.rb
```
Esperado: ALL PASS.

- [ ] **Step 4: Lint backend dos arquivos tocados**

Run: `bundle exec rubocop app/models/ticket/satisfaction_rating.rb app/models/ticket/assets.rb app/controllers/csat_ratings_controller.rb app/policies/controllers/csat_ratings_controller_policy.rb`
Esperado: sem offenses.

- [ ] **Step 5: Commit i18n**

```bash
git add i18n/zammad.pot i18n/zammad.pt-br.po
git commit -m "feat(csat): i18n strings (pt-BR) for the legacy rating popup"
```

- [ ] **Step 6: QA manual (com o app rodando — `bin/dev`)**

- [ ] CSAT OFF: como Cliente, abrir ticket fechado → **sem popup**.
- [ ] Ligar `csat_integration` (`Setting.set('csat_integration', true)` ou admin). Como **Cliente** (login do cliente, UI clássica `/`), abrir um ticket fechado não avaliado → **popup aparece**.
- [ ] Escolher 4 estrelas + comentário → Enviar → fecha + aviso "Obrigado"; reabrir o ticket → **não reaparece**.
- [ ] Em outro ticket fechado: clicar **"Agora não"** (ou X/Esc) → fecha e **não reaparece** (localStorage); clicar fora **não** fecha.
- [ ] Ao vivo: Cliente com o ticket aberto; Atendente finaliza → popup aparece **na hora** (re-fetch REST).
- [ ] Atendente/Admin abrindo o mesmo ticket → **sem popup** (não é o cliente).
- [ ] `csat_comment=required` → Enviar sem comentário é bloqueado; `csat_comment=off` → sem campo de comentário.
- [ ] `GET /api/v1/csat/surveys` (admin) mostra a nova avaliação com `agent_id` = dono no momento.
- [ ] Atribuição imutável: reatribuir o ticket depois **não** muda o `agent_id`.

---

## Cobertura do spec (auto-revisão)

| Seção do spec | Task(s) |
|---|---|
| `ratable?` (fonte única) | Task 1 |
| Expor `satisfaction_ratable` no payload REST | Task 2 |
| `POST /csat/ratings` + auth no registro | Task 3 |
| Modal (estrelas Safari-safe, comentário por `csat_comment`, fechar=dispensa, backdrop estático) | Task 4 |
| Gatilho abertura + ao vivo (via re-fetch REST) | Task 5 |
| i18n pt-BR | Task 6 |
| Reuso (modelo/policy/settings/REST-leitura) | já existente (não tocado além do `ratable?`) |
| Limpeza (revert Vue/GraphQL) | já feito (commits `e8548423`, `dc86a592`, `e52f8751`) |
```
