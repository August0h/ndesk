# CSAT (Satisfação do Cliente)

Contexto da feature de CSAT do NDesk: o Cliente avalia a resolução do problema e o atendimento (duas notas 1–5) num popup dentro do ticket finalizado; a avaliação é creditada a um Atendente Avaliado e exposta a Admins (no app e via API REST). Glossário — sem detalhes de implementação.

## Linguagem

**Avaliação de Satisfação (CSAT)**:
O par de notas 1–5 — Nota de Resolução e Nota de Atendimento — (com comentário opcional) que um Cliente dá a um atendimento finalizado. Uma por ticket, gravada uma única vez. No código: `Ticket::SatisfactionRating`.
_Evitar_: pesquisa, survey, feedback, NPS, "rating" genérico

**Nota de Resolução**:
A nota 1–5 que o Cliente dá à resolução do problema, primeira pergunta do popup. Nula nas Avaliações registradas antes da dimensão existir. No código: `score_resolution`.
_Evitar_: nota do problema, score de solução

**Nota de Atendimento**:
A nota 1–5 que o Cliente dá ao atendimento em si — *como foi atendido*, em contraste com a resolução —, segunda pergunta do popup. "Atendimento" sem qualificador segue sendo a experiência toda do ticket finalizado (sentido do título do popup); as Avaliações antigas (nota única) são Notas de Atendimento (ver ADR 0003). No código: `score_service`.
_Evitar_: score (ambíguo), nota geral

**Atendente Avaliado**:
O atendente a quem uma Avaliação é creditada. Copiado do `owner` do ticket no momento da avaliação e imutável depois — não muda se o ticket for reatribuído. É o **dono (owner) atribuído**, não quem clicou em "Fechar". No código: `agent_id`.
_Evitar_: dono/owner (esse é o campo vivo do ticket), responsável atual, quem fechou

**Cliente**:
A pessoa dona do ticket (`Ticket#customer`) — a única que pode avaliar aquele atendimento. Colegas da mesma organização não avaliam.
_Evitar_: usuário, solicitante (são mais amplos que o Cliente do ticket)

**Finalizado**:
Estado do ticket cuja **categoria** (`state_type`) dispara o popup de avaliação. No NDesk hoje: apenas "Fechado" (categoria `closed`). Configurável via `csat_closed_state_types`.
_Evitar_: resolvido, encerrado, concluído (são nomes de estado; o que importa é a categoria `closed`)

**Taxa de Resposta**:
Dos atendimentos **finalizados** numa janela de tempo (campo `close_at` do ticket no período), a fração que recebeu Avaliação. É uma métrica **geral** (não calculada por Atendente Avaliado).
_Evitar_: engajamento, adesão, conversão
