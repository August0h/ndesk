---
status: accepted
---

# Avaliação de satisfação embutida no payload do ticket, sem gating de permissão

`GET /api/v1/tickets` e `/api/v1/tickets/:id` passam a incluir o objeto `satisfaction`
(nota/comentário/atendente) sempre que o ticket tem uma Avaliação, **sem checar permissão** — porque
a API REST do NDesk é usada apenas por admins/integrações. Isso cria, deliberadamente, **duas portas**
para o mesmo dado: o endpoint `/api/v1/csat/surveys` (bloqueado por `csat.read`) e o payload do ticket
(sem controle).

## Consequência / risco aceito

Um Atendente **sem `csat.read`**, com um token de API, poderia ler a nota + comentário do Cliente nos
tickets que ele enxerga, via o payload do ticket (no `/surveys` isso seria 403). **Aceito** porque a API
é admin-only. **Reabrir** esta decisão (gatear o embutido por `csat.read` + dono, igual ao `/surveys`) se
acesso de API por não-admins passar a existir.

> Nota: o booleano `satisfaction_ratable` continua per-user (lógica do popup do Cliente) — este ADR é
> sobre o objeto `satisfaction` (os dados da nota).
