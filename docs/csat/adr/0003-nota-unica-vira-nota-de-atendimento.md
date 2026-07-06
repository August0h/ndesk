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
