# Taskbar (UI clássica)

Contexto da sidebar esquerda da UI clássica do NDesk: a lista de abas abertas que o
atendente organiza em coleções nomeadas. Glossário — sem detalhes de implementação.

## Linguagem

**Taskbar**:
A lista de Abas na sidebar esquerda da UI clássica — o que o atendente tem aberto agora,
persistido por usuário e restaurado no login. No código: `Taskbar` / `App.TaskManager`.
_Evitar_: histórico (sugere tickets já fechados), lista de tarefas

**Aba**:
Uma entrada da Taskbar — um ticket, usuário, organização ou rascunho aberto. Fechar a Aba
(×) não altera o objeto que ela mostra. No código: task, com key `Ticket-123`, `User-45`…
_Evitar_: task/tarefa (em prosa), "ticket aberto" (nem toda Aba é ticket)

**Coleção**:
Conjunto nomeado de Abas que o atendente monta por arrastar-e-soltar para organizar a
Taskbar. Só contém Abas vivas: fechar a Aba a remove, e Coleção vazia deixa de existir.
Uma Aba pertence a no máximo uma Coleção. No código: `TaskbarCollections` /
`taskbar_collections`.
_Evitar_: grupo (no Zammad é o departamento do ticket), pasta, agrupamento

**Aba Solta**:
Aba fora de qualquer Coleção — o estado natural de toda Aba ao ser aberta (ou reaberta,
mesmo que já tenha pertencido a uma Coleção).
_Evitar_: aba não agrupada
