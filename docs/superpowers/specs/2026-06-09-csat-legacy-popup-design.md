# CSAT — Popup do Cliente na UI Antiga (legacy) — Design

> **Supersede:** substitui a camada GraphQL + UI desktop (Vue) do design original
> (`2026-06-09-csat-design.md`). Essa parte foi **revertida** (commits `e8548423`,
> `dc86a592`, `e52f8751`). O backend reaproveitável permanece.

## Objetivo

Quando o **Cliente** abre, na **interface antiga** (desktop-app legacy: Spine.js/CoffeeScript + REST),
um ticket **finalizado** (categoria de estado `closed`) que ainda não avaliou, exibir um **popup**
para dar uma nota de **1–5 estrelas + comentário opcional**. A nota é gravada uma única vez,
imutável, creditada ao atendente dono no momento da avaliação. Admins consultam os resultados
pela **API REST** que já existe (`/api/v1/csat/surveys`, `/api/v1/csat/stats`).

**Fora de escopo:** exibição in-app para o admin (só via API REST); UI nova (`/desktop`); mobile; e-mail/página externa/token público.

## Contexto / o que já existe (reaproveitado, não muda)

- Modelo `Ticket::SatisfactionRating` (+ tabela, factory, specs) — inclui `before_create` que faz o snapshot do atendente (owner / fallback por histórico) e `attr_readonly` (imutável).
- `has_one :satisfaction_rating` em `Ticket`.
- Permissões `csat.read` / `admin.csat`; settings `csat_integration` (bool, frontend), `csat_comment` (`off`/`optional`/`required`, frontend), `csat_closed_state_types` (array, backend). Migração de deploy para installs existentes.
- `Ticket::SatisfactionRatingPolicy` (`create?` / `show?`).
- API REST de leitura: `CsatSurveysController#index`, `CsatStatsController#index`, `Service::Csat::Stats`, rotas em `config/routes/csat.rb`, controller-policies.

## Arquitetura (alto nível)

```
Cliente abre ticket fechado (legacy ticket_zoom)
        │  GET /tickets/:id?all=true   ← payload já traz satisfaction_ratable (NOVO)
        ▼
ticket_zoom.coffee detecta: view=customer + dono + ratable + não-dispensado
        ▼
abre App.CsatModal (Spine ControllerModal)  →  estrelas 1–5 + comentário (conforme csat_comment)
        │  POST /api/v1/csat/ratings {ticket_id, score, comment}   (NOVO)
        ▼
CsatRatingsController#create → authorize!(rating, :create?) [policy existente] → save
        ▼
modal fecha; "Agora não" grava dispensa em App.LocalStorage (não reabre)
```

Gatilho dispara **no `load()` do ticket_zoom** (evento `ui::ticket::all::loaded`), que roda tanto na **abertura** quanto em **toda atualização ao vivo**. O ao-vivo funciona porque o legacy, ao receber o push `Ticket:update`, chama `fetchMayBe → fetch()` = um **GET REST `?all=true` novo**, recomputando `satisfaction_ratable` fresco a cada vez (não é patch local). Isso evita o problema do Safari da tentativa Vue (lá era cache-first + subscription que, ao cair em aba background, deixava cache velho); aqui há re-fetch via REST + re-fetch no `ws:login` (reconexão) + pull de 30 min de fallback.

## Componentes

### Backend (2 adições pequenas + 1 refactor DRY)

1. **Lógica `ratable?` como fonte única de verdade.** Extrair as 4 checagens (CSAT ligado + usuário é o cliente do ticket + `state_type` ∈ `csat_closed_state_types` + sem avaliação prévia) para um método de classe `Ticket::SatisfactionRating.ratable?(ticket:, user:)`. A `Ticket::SatisfactionRatingPolicy#create?` passa a usá-lo (hoje a regra está duplicada).

2. **Expor `satisfaction_ratable` no payload REST do ticket.** Override de `filter_unauthorized_attributes` em `Ticket::Assets` (padrão usado por `User`/`Role`): se `csat_integration` ligado, adiciona `satisfaction_ratable = Ticket::SatisfactionRating.ratable?(ticket: self, user: <usuário autenticado>)`. Aplica-se a todos os caminhos REST (`?all`, `?expand`, default) sem N+1 e sem coluna nova.

3. **Endpoint REST de criação.** `POST /api/v1/csat/ratings` → `CsatRatingsController#create`:
   - `prepend_before_action :authentication_check` (NÃO `authenticate_and_authorize!`, para o cliente sem `csat.read` poder enviar);
   - monta o rating (`ticket`, `customer: current_user`, `score`, `comment` respeitando `csat_comment == 'off'` → nil);
   - `authorize!(rating, :create?)` (gating no registro pela policy existente);
   - `save!`; trata `RecordInvalid` → 422.
   - Controller-policy `Controllers::CsatRatingsControllerPolicy` com `default_permit!('admin')` (bypass; quem decide é a policy do registro). Padrão idêntico ao `TicketArticlesController`.
   - Rota nova em `config/routes/csat.rb`.

### Frontend (legacy / Spine / CoffeeScript)

4. **Modal** `app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee` (estende `App.ControllerModal`):
   - `content()` → `App.view('ticket_zoom/csat_modal')(...)`.
   - `buttonSubmit: 'Submit'`, `buttonCancel: 'Not now'`.
   - `onSubmit`: lê score (obrigatório) + comentário; `App.Ajax` `POST /api/v1/csat/ratings`; em **sucesso** fecha + notificação rápida de agradecimento (`App.Event.trigger('notify', ...)` / padrão do app); em **erro** mostra alerta no próprio modal (mantém aberto).
   - **Fechamento (importante — interage com o gatilho ao-vivo B):** backdrop **estático** (clicar fora não fecha → evita dispensa acidental). **Todo** fechar-sem-enviar (X, Escape, "Agora não") grava `App.LocalStorage.set('csat_dismissed_ticket_' + ticket_id, true)`, para que atualizações ao vivo do ticket **não** reabram o popup depois de fechado. "Enviar" não precisa do flag (após avaliar, `satisfaction_ratable` vira false).

5. **Template** `app/assets/javascripts/app/views/ticket_zoom/csat_modal.jst.eco`:
   - Widget de 1–5 estrelas (SVG/`@Icon('star')` **Safari-safe** — sem `url(#id)` dentro de `<symbol>/<use>`; fill inline).
   - `textarea` de comentário exibida conforme `App.Config.get('csat_comment')` (`off` esconde; `required` torna obrigatório).
   - Strings via `@T(...)`.

6. **Gatilho** (abertura **e** ao vivo) ligado ao evento `ui::ticket::all::loaded` do `ticket_zoom.coffee`:
   - Esse evento roda no `load()`, que é chamado na **abertura** e também em **cada atualização ao vivo** (push `Ticket:update` → `fetchMayBe → fetch()` = GET REST `?all=true` novo → `satisfaction_ratable` recomputado).
   - Ao disparar, checar: `currentView() == 'customer'` **e** `customer_id == App.User.current().id` **e** `satisfaction_ratable` (do payload fresco) **e** `!App.LocalStorage.get('csat_dismissed_ticket_' + ticket_id)` → instanciar `App.CsatModal`. Escopar pelo `ticket_id` do evento (evento é global, pode haver várias abas).
   - Resultado: se o Atendente finaliza com o Cliente olhando, o popup abre na hora (via re-fetch REST); senão, abre quando o Cliente abrir o ticket finalizado.

7. **SCSS** mínimo em `app/assets/stylesheets/zammad.scss` (`.csat-modal` estrelas/hover; dark mode via `@include dark`).

8. **i18n**: strings novas via `@T()` (extraídas pelo gerador de catálogo, que varre `.jst.eco`/`.coffee`) + traduções pt-BR (`Avalie este atendimento`, `Como foi o seu atendimento?`, `Comentário`, `Enviar`, `Agora não`, etc.).

## Fluxo de dados & autorização

- **Leitura do "ratable":** só é `true` para o **cliente do ticket** (o override usa o usuário autenticado); para atendente/admin vem `false`/ausente — o popup nunca dispara para eles.
- **Criação:** a `SatisfactionRatingPolicy#create?` recusa se CSAT desligado, se quem chama não é o cliente, se o ticket não está finalizado, ou se já existe avaliação → o endpoint retorna 403/422 nesses casos.
- **Atribuição imutável:** garantida pelo `before_create` + `attr_readonly` já existentes no modelo.

## Tratamento de erros

- `POST /csat/ratings`: não-cliente → 403; ticket não-finalizado → 403; nota duplicada → **403** (recusada pela policy `already_rated?`); corrida de duplicação (índice único `(ticket_id, customer_id)`) → 422 (`RecordNotUnique`); payload inválido → 422. O modal exibe a mensagem e mantém o popup aberto em erro.
- `App.LocalStorage` lança em cota cheia (Safari privado) — já tratado internamente (try/catch); a dispensa é best-effort.
- **Deploy guard:** `assets:precompile` (Sprockets) precisa continuar verde — CoffeeScript/SCSS limpos; arquivos novos são auto-incluídos via `require_tree` (sem editar manifest).

## Estratégia de testes

- **Backend (TDD, RSpec):**
  - `Ticket::SatisfactionRating.ratable?` (unit) — as 4 condições.
  - Request spec `POST /api/v1/csat/ratings`: cliente → 201; não-cliente → 403; ticket aberto → 403; segunda avaliação → 403; `csat_comment == 'off'` → comentário não persiste.
  - Spec do payload do ticket: `satisfaction_ratable` presente/`true` só para o cliente quando avaliável; ausente/`false` caso contrário.
  - Regressão: specs mantidos (`/surveys`, `/stats`, policy, modelo, seeds) continuam verdes.
- **Frontend legacy:** o app antigo praticamente não tem teste unitário de controller (QUnit esparso). Cobertura via **checklist de QA manual** (no plano) + as request specs do backend. (Sem Vitest aqui — é a UI antiga.)

## Riscos / decisões

- **Gatilho abertura + ao vivo (opção B, escolhida):** funciona ao vivo porque o legacy re-busca via REST a cada `Ticket:update` (`fetchMayBe → fetch`), recomputando o flag — não é cache-first como no Vue, então não tem o problema de aba background do Safari. Resiliência extra: re-fetch no `ws:login` + pull de 30 min.
- **Safari:** estrelas sem `url(#id)` em symbols (lição do `NEWBYTE_WORKFLOW.md`).
- **`filter_unauthorized_attributes`:** confirmar a assinatura/local exatos em `Ticket::Assets` na implementação (TDD com a spec de payload prova o hook).

## Follow-ups conhecidos (minor, não-bloqueantes — da revisão final)

Veredito da revisão final = **SHIP** (sem críticos/importantes). Itens de polish para depois:
- **Dark-mode do `.csat-modal`**: as cores são legíveis no tema escuro, mas falta um bloco `@include dark` afinado (design §7). Opcional.
- **N+1 (lista do cliente)**: `already_rated?` roda um `EXISTS` por ticket fechado na lista — limitado (cliente tem poucos tickets, índice único), aceito (decisão Q2). Otimizar só se aparecer.
- **N+1 (`/csat/surveys`)**: `rating.agent&.fullname` por linha (até 100) — endpoint admin, fora do hot path; `includes(:agent)` resolve. Opcional.
- **Catálogo i18n**: as msgids novas foram adicionadas de forma focada (sem `#:` refs); uma regeneração futura com a tooling do Zammad normaliza referências/stubs. Tradução pt-BR em runtime não é afetada.

## Limpeza (já feita)

Revertidos os 10 commits da camada GraphQL + UI Vue (Tasks 4–5 e 8–12). Backend reaproveitável intacto e verde.
