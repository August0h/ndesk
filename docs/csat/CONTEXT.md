# CSAT (Satisfação do Cliente)

Contexto da feature de CSAT do NDesk: o Cliente avalia o atendimento (1–5 estrelas) num popup dentro do ticket finalizado; a nota é creditada a um Atendente Avaliado e exposta a Admins (no app e via API REST). Glossário — sem detalhes de implementação.

## Linguagem

**Avaliação de Satisfação (CSAT)**:
A nota de 1–5 (com comentário opcional) que um Cliente dá a um atendimento finalizado. Uma por ticket, gravada uma única vez. No código: `Ticket::SatisfactionRating`.
_Evitar_: pesquisa, survey, feedback, NPS, "rating" genérico

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
