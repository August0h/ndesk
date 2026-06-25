# CSAT — Embutir a avaliação no payload REST do ticket — Design

> Extensão do CSAT (ver `2026-06-09-csat-legacy-popup-design.md` e ADR `docs/csat/adr/0001`).
> O endpoint separado `/api/v1/csat/surveys` continua intacto.

## Objetivo

Expor a **Avaliação de Satisfação** de um ticket dentro das respostas REST `GET /api/v1/tickets`
(lista) e `GET /api/v1/tickets/:id`, em **todas as formas** (GET puro **e** `?expand`/`?full`/`?all`),
para consumo por integrações **admin**. Já existe o booleano `satisfaction_ratable` no payload (caminhos
de assets); agora adiciona-se o **objeto `satisfaction`** com os dados da nota, e estende-se a cobertura ao
**GET puro** (sem params).

## Decisões (do brainstorm)

- **Sem controle de acesso** no objeto embutido: a API é usada só por admins. O objeto `satisfaction` é
  incluído sempre que o ticket tiver avaliação, para qualquer requisitante. (O `satisfaction_ratable`
  permanece per-user — é a lógica do popup do Cliente.) Premissa registrada na **ADR
  `docs/csat/adr/0002-satisfaction-embutida-no-payload-do-ticket.md`** (duas portas pro mesmo dado: o
  `/surveys` gated e o payload do ticket sem controle — risco do atendente-sem-`csat.read`-com-token aceito).
- **Cobrir o GET puro** (sem params), além de `?expand`/`?full`/`?all`.

## Formato

Adicionado ao payload do ticket (junto de `satisfaction_ratable`):

```json
"satisfaction": {
  "score": 4,
  "comment": "Ótimo atendimento",
  "agent_id": 42,
  "agent_name": "Agent 1 Test",
  "group_id": 1,
  "created_at": "2026-06-11T12:00:00Z"
}
```

- `agent_name` = `fullname` do Atendente Avaliado (ou `null`).
- Ticket sem avaliação → `satisfaction` é `null` (presente como chave nula).
- Não depende de `csat_integration`: dados históricos aparecem mesmo se a feature for desligada depois.

## Arquitetura (DRY — um helper, dois pontos de injeção)

1. **Helper único** no modelo `Ticket` (ex.: `Ticket#satisfaction_api_attributes(user)`), retornando
   `{ 'satisfaction_ratable' => bool, 'satisfaction' => hash|nil }`. Fonte única do shape.
2. **`Ticket::Assets#filter_unauthorized_attributes`** (que já injeta `satisfaction_ratable`) passa a usar o
   helper e injetar também `satisfaction` → cobre `?expand`/`?full`/`?all` (inclui o `?all=true` do ticket_zoom).
3. **`TicketsController#show` e `#index`**, no render **default** (`render json: ticket` / `tickets`),
   fazem `as_json.merge(helper)` → cobre o **GET puro**.

## Performance

No `index`, adicionar `.includes(satisfaction_rating: :agent)` ao scope → evita N+1 ao montar `satisfaction`
+ `agent_name` na lista (paginada, max 100).

## Fora de escopo

- Sem mudança no `/csat/surveys`/`/stats`.
- Sem exibição na UI (legacy não tem widget de avaliação para atendente).
- Sem alteração do shape default em outros controllers que serializam Ticket (mudança escopada a
  `TicketsController#index/#show`).

## Testes

- Request spec `GET /api/v1/tickets/:id` (puro **e** `?expand`): com avaliação → objeto `satisfaction`
  com score/comment/agent_id/agent_name/group_id/created_at; sem avaliação → `satisfaction` nulo.
- Request spec `GET /api/v1/tickets` (lista, puro **e** `?expand`): idem por ticket.
- Regressão: `satisfaction_ratable` continua presente; specs de enumeração não afetadas.
