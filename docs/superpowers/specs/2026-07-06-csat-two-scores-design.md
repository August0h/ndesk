# CSAT — Duas dimensões de avaliação (resolução + atendimento) — Design

> Extensão do CSAT (ver `2026-06-09-csat-legacy-popup-design.md`,
> `2026-06-11-csat-ticket-api-embed-design.md` e ADRs `docs/csat/adr/0001` e `0002`).

## Objetivo

Separar a **Avaliação de Satisfação** em duas notas 1–5: **Nota de Resolução**
("Como você avalia a resolução do problema?") e **Nota de Atendimento**
("Como você avalia o atendimento?") — nessa ordem no popup. A avaliação continua
sendo **um registro único** por (ticket, cliente): um envio, um comentário opcional,
um snapshot de atendente/grupo, write-once.

## Decisões (do brainstorm)

- **Dado antigo vira Nota de Atendimento**: o popup sempre perguntou "Como foi o seu
  atendimento?", então o `score` já registrado em produção tem essa semântica. A Nota de
  Resolução fica `NULL` nas avaliações antigas (o Cliente nunca a deu). Rejeitados:
  tratar o histórico como dimensão legada separada; copiar a nota antiga para as duas
  dimensões. → registrar em **ADR 0003**.
- **Ambas obrigatórias** no envio: o submit só passa com as duas notas. Comentário segue
  a setting `csat_comment`, como hoje.
- **Par simétrico renomeado**: coluna e API trocam `score` por `score_service` +
  `score_resolution`. Não há integração externa lendo `satisfaction.score` nem filtrando
  `/surveys?score=`, e o dashboard admin ainda não existe — é a última janela barata para
  o rename. Rejeitado: manter `score` (= atendimento) e só adicionar a segunda coluna
  (assimetria permanente).
- **Sem alias `score` no POST**: com ambas obrigatórias, uma aba antiga ainda aberta no
  momento do deploy tomaria 422 de qualquer forma (faltaria a resolução). Nada é gravado;
  se o cliente fechar o modal após o erro, a dispensa (LocalStorage) suprime o popup
  daquele ticket — no pior caso perde-se essa uma avaliação. Janela minúscula, perda
  aceita.
- **Estrutura: segunda coluna na mesma tabela**. Rejeitados: tabela genérica de dimensões
  (são exatamente 2 e estáveis — YAGNI; complicaria stats/serializers/migração) e um
  registro por dimensão (quebra a unicidade por ticket+cliente, duplica comentário e
  snapshot, complica o "já avaliado").

## Dados & migração

Uma migração em `db/migrate`:

- `rename_column :ticket_satisfaction_ratings, :score, :score_service` — instantâneo no
  Postgres; o dado antigo vira Nota de Atendimento sem UPDATE em massa/backfill.
- `add_column :ticket_satisfaction_ratings, :score_resolution, :integer, null: true` —
  `NULL` permitido no banco porque as linhas antigas legitimamente não têm essa nota.

No modelo `Ticket::SatisfactionRating`:

- `score_service`: presença + inclusão 1..5 (igual à validação atual do `score`).
- `score_resolution`: presença + inclusão 1..5 **`on: :create`** — obrigatória em toda
  avaliação nova; se algum fluxo futuro regravar uma linha antiga (ex.: `comment`, que
  não é readonly), a linha legada não se torna inválida.
- `attr_readonly` passa a cobrir os dois scores (write-once preservado).
- Unicidade (ticket, cliente), snapshot de atendente/grupo, policy e `ratable?`:
  **intocados**.

## API REST

- **`POST /api/v1/csat/ratings`**: aceita `score_service` + `score_resolution` (ambos
  obrigatórios). Resposta serializa os dois. Sem alias para o param antigo `score`.
- **`GET /api/v1/tickets` e `/tickets/:id`** (embed): o objeto `satisfaction` troca a
  chave `score` por `score_service` + `score_resolution` (avaliações antigas:
  `score_resolution: null`). Vale para os dois pontos de injeção do helper único
  `Ticket#satisfaction_api_attributes` — GET puro e `?expand`/`?full`/`?all`.
  `satisfaction_ratable` não muda.
- **`GET /api/v1/csat/surveys`**: serializa os dois scores; o filtro `?score=` é
  substituído por `?score_service=` e `?score_resolution=`.
- **`GET /api/v1/csat/stats`**: shape ganha um bloco por dimensão:

```json
{
  "overall": {
    "count": 120,
    "response_rate": 0.43,
    "service":    { "count": 120, "average": 4.5, "distribution": { "1": 2, "2": 3, "3": 15, "4": 40, "5": 60 } },
    "resolution": { "count": 80,  "average": 4.1, "distribution": { "1": 5, "2": 5, "3": 15, "4": 25, "5": 30 } }
  },
  "by_agent": [
    { "agent_id": 5, "agent": "Nome", "count": 30, "count_resolution": 18,
      "average_service": 4.6, "average_resolution": 4.2 }
  ]
}
```

- `overall.count` = total de avaliações; o `count` de cada dimensão conta só as notas
  não-nulas daquela dimensão (antigas não têm resolução). Em `by_agent`, `count` = total
  de avaliações do atendente (que é também o n do serviço — coluna NOT NULL) e
  `count_resolution` = n da média de resolução — sem ele, uma média de resolução com n=1
  pareceria ter o peso do `count` total. As médias por dimensão ignoram `NULL` (`AVG` e
  `COUNT(coluna)` ignoram `NULL` naturalmente no SQL). `response_rate` inalterada
  (independe de dimensão).
- O dashboard admin ainda não existe, então o shape novo não quebra consumidor algum.

## UI clássica (popup)

- **Template** (`csat_modal.jst.eco`): duas fileiras de estrelas empilhadas, cada uma com
  label — primeiro **"Como você avalia a resolução do problema?"**, depois
  **"Como você avalia o atendimento?"** — e o comentário como hoje. Uma mensagem de erro
  única. Cada fileira é um `role="group"` com `aria-labelledby` apontando para o seu label
  (com uma fileira só, o contexto era inequívoco; com duas, o leitor de tela precisa saber
  a qual pergunta cada estrela pertence — sem strings novas de i18n).
- **Controller** (`csat_modal.coffee`): estrelas com `data-dimension="resolution|service"`;
  estado `@scores` por dimensão; clicar numa fileira pinta só ela. Validação no submit: se
  faltar qualquer nota → "Selecione uma nota nos dois campos." (comentário obrigatório
  segue a setting, como hoje). POST com os dois campos.
- **SCSS**: reuso das classes atuais das estrelas; só espaçamento entre os grupos.
  Estrelas continuam texto "★" (Safari-safe, sem SVG).
- **Gatilhos intocados**: abertura no ticket finalizado, dispensa por usuário
  (LocalStorage), re-fetch REST ao finalizar ao vivo.
- **i18n pt-BR**: novas strings (dois labels + erro). "How was your support?" e
  "Please select a rating." deixam de ser usadas e saem do template/controller e do
  `.po`. O título "Rate this ticket" → "Avalie este atendimento" fica.

## Testes

- **Model spec**: validações dos dois scores (incl. `on: :create` da resolução),
  `attr_readonly` de ambos.
- **Request specs**:
  - POST: sucesso com ambos; 422 faltando cada um; 422 de aba antiga mandando só `score`.
  - Surveys: serialização com os dois scores + filtros `score_service`/`score_resolution`.
  - Stats: agregados por dimensão com avaliação legada (`score_resolution: NULL`) no meio
    — counts diferentes por dimensão, médias corretas.
  - Embed no ticket: as duas chaves; avaliação legada com `score_resolution: null`.
- **Factory**: `ticket_satisfaction_rating` com os dois scores + trait de avaliação
  legada (`score_resolution: nil`).
- **QA manual** ponta-a-ponta na UI clássica (Chromium + WebKit), como na PR original.

## Docs

- `docs/csat/CONTEXT.md`: "Avaliação de Satisfação" passa a ser duas notas 1–5 +
  comentário; entram os termos **Nota de Resolução** e **Nota de Atendimento**.
- **ADR 0003**: o score único histórico torna-se Nota de Atendimento (alternativas
  rejeitadas registradas).
- Entrada no changelog do `.claude/NEWBYTE_WORKFLOW.md` ao final da sessão.

## Fora de escopo

- Dashboard admin de CSAT (PR futura) — esta mudança só deixa a API pronta.
- UI nova (Vue/desktop-view) — ADR 0001 continua valendo.
- Nenhuma mudança em permissões, settings ou gatilhos do popup.

## Entrega

- Branch `feat/csat-two-scores` criada de `origin/newbyte-stable` (`feat/csat-legacy`
  confirmada 100% mergeada); PR contra `newbyte-stable`; tag `nb.v{next}` no merge
  (perguntar a versão antes de criar).
