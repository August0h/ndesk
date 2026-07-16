---
status: accepted
---

# Coleções persistem em `user.preferences`, e a ordem pega carona no `prio` da taskbar

As Coleções de Abas vivem num documento único por usuário
(`user.preferences.taskbar_collections`: id, nome, recolhida, keys das Abas), salvo pelo
`PUT /api/v1/users/preferences` existente — que faz merge por chave de topo, então a
gravação não toca outras preferências. Não há tabela, migração, endpoint ou modelo novo:
o backend não sabe que Coleções existem. A ordem visual **não tem campo próprio**: os
membros de uma Coleção mantêm `prio`s contíguos na taskbar e a Coleção ancora no membro
de menor `prio`.

## Alternativas rejeitadas

- **Metadado de coleção no `params` de cada aba** (carona no save da taskbar): o
  `params` é repassado como argumento ao controller da aba pelo upstream — contaminá-lo
  arrisca efeito colateral silencioso em upgrade; renomear regravaria N abas; o nome
  duplicado em cada membro pode divergir.
- **Tabela `taskbar_collections` de primeira classe** (+ coluna na `taskbars` + REST):
  modelo mais "correto", mas custa migração, modelo, policy, controller e Spine model, e
  toca a tabela `taskbars` do upstream — esforço e superfície de conflito com upgrades
  do Zammad desproporcionais para organização visual per-user.

## Consequências

- **Reconciliação é client-side**: no init da taskbar (evento `taskbar:init`, do login)
  e no fechamento de Aba, keys órfãs são descartadas e Coleção vazia some. O servidor
  nunca valida o documento. **Nunca reconciliar no logout** (`taskInit` do `reset()`,
  lista de Abas já vazia) — reconciliar ali apagaria o documento inteiro. Como logout →
  login não recarrega a página, o documento é relido da sessão a cada login (cobre troca
  de usuário no mesmo browser).
- **Last-write-wins**: edição simultânea em dois dispositivos sobrescreve o documento
  inteiro (dentro da chave `taskbar_collections`). Aceito para organização pessoal.
- **Outros clientes (Vue/mobile) não conhecem Coleções** e podem intercalar os prios ao
  reordenar; a renderização clássica tolera (sempre junta os membros na âncora) e o init
  não grava ordem de volta — prios só são normalizados na próxima mudança estrutural
  feita na UI clássica.
- **Reverter depois = migrar preferência de todos os usuários** para o novo lugar.
