---
status: accepted
---

# CSAT do cliente na UI clássica (legacy), não no app desktop novo (Vue)

O popup de avaliação (CSAT) para o Cliente é implementado na **UI clássica** do Zammad
(desktop-app legacy: Spine.js/CoffeeScript + REST), porque a base de clientes da NewByte usa
essa interface — a UI nova (`/desktop`, Vue) é beta e opt-in, então um popup só nela não
alcançaria os clientes. O backend de domínio (modelo `Ticket::SatisfactionRating`, permissões,
settings, policy e a API REST de leitura) é compartilhado e independe da UI.

## Alternativas consideradas (e por que rejeitadas)

Uma primeira versão foi construída no **app desktop novo (Vue) + GraphQL** (popup Vue, composable,
painel lateral, mutation/fields GraphQL) e depois **revertida** (commits `e8548423`, `dc86a592`,
`e52f8751`). Motivo: os clientes não usam a UI nova, então a feature não chegava a eles. Registramos
isto para que ninguém re-sugira "fazer no app moderno/GraphQL" sem antes confirmar onde os clientes
realmente estão.

## Consequências

- O gatilho do popup usa o **re-fetch REST** do `ticket_zoom` legacy (a cada `Ticket:update` →
  `fetch()`), recomputando `satisfaction_ratable` no servidor. Isso evita a fragilidade de
  cache-first + subscription que quebrava no Safari (aba em segundo plano) na tentativa Vue.
- A criação da avaliação precisa de um endpoint **REST** (`POST /api/v1/csat/ratings`), já que a UI
  legacy não usa GraphQL.
- Se um dia os clientes migrarem para a UI nova, o popup precisará ser re-portado para lá (o backend
  REST/modelo continua válido).
