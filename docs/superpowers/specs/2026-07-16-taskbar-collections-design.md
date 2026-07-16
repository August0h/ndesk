# Coleções de abas na taskbar (sidebar esquerda) — Design

> Linguagem do domínio em `docs/taskbar/CONTEXT.md` (Taskbar, Aba, Coleção, Aba Solta).

## Objetivo

Deixar o atendente organizar as **Abas** da sidebar esquerda (a taskbar da UI clássica:
tickets, usuários, organizações, rascunhos) em **Coleções nomeadas**, criadas por
arrastar-e-soltar: soltar uma Aba sobre o miolo de outra cria uma Coleção; a Coleção
lista as Abas, pode ser renomeada, recolhida, desfeita e movida como uma unidade.

## Terminologia

Termo canônico: **Coleção** (ver `docs/taskbar/CONTEXT.md`). "Grupo" é proibido nesta
feature — no Zammad, Group é o **departamento** do ticket, exibido como "Grupo" na mesma
tela. No código: **`TaskbarCollections`** / **`taskbar_collections`** (o prefixo
`Taskbar` desambigua do `App.Collection`, store central de dados do app legacy).

## Decisões (do brainstorm)

- **A Coleção organiza Abas vivas** (estilo grupos de abas do Chrome): só contém Abas
  presentes na taskbar. Fechar a Aba a tira da Coleção; Coleção que esvazia some; Aba
  reaberta depois volta **Solta**. Rejeitado: pasta persistente que guarda tickets com
  aba fechada (vira outra feature — favoritos/bookmarks).
- **Qualquer tipo de Aba pode entrar em Coleção** (ticket, usuário, organização,
  rascunho). Rejeitado: restringir a tickets (regra por tipo sem ganho real).
- **Nome editável na criação**: ao criar a Coleção, o cabeçalho abre com input focado
  (Enter confirma; Esc/blur mantém o padrão "Coleção N"). Renomear depois pelo menu.
  Rejeitados: só nome automático; nome inteligente derivado do cliente/organização.
- **Cabeçalho com menu de contexto (⋯)**: clicar no cabeçalho recolhe/expande; o ⋯
  (hover) abre menu com **Renomear**, **Desfazer coleção** e **Fechar todas as abas**.
  Rejeitados: × minimalista que desfaz a Coleção (esconde o "fechar todas"); lápis + ×
  explícitos (sem lugar para desfazer).
- **Abas em Coleção ficam protegidas da limpeza automática** (`tasksAutoCleanup`):
  colecionar é organização deliberada; só Abas Soltas são candidatas ao fechamento
  automático.
- **Persistência: documento único em `user.preferences`** (abordagem B). Rejeitados:
  metadado de coleção no `params` de cada aba (o `params` é repassado ao controller da
  aba pelo upstream — contaminá-lo é frágil; rename regravaria N abas); tabela
  `taskbar_collections` de primeira classe (migração + modelo + policy + controller +
  Spine model, e toca a tabela `taskbars` do upstream — esforço e superfície de conflito
  desproporcionais para organização visual per-user).

## Modelo de dados & persistência

Uma chave nova nas preferências do usuário:

```coffee
user.preferences.taskbar_collections = [
  { id: 'c-a1b2c3', name: 'Projeto ERP', collapsed: false,
    keys: ['Ticket-67005', 'Ticket-67022', 'Ticket-67010'] }
]
```

- `id` gerado no cliente (timestamp + aleatório), estável para rename/collapse.
- `keys` = keys da taskbar (`Ticket-123`, `User-45`…), na ordem interna da Coleção.
- Save com debounce via `PUT /api/v1/users/preferences` (endpoint existente; faz merge
  por chave de topo sob lock — gravar `taskbar_collections` não toca outras
  preferências). Nenhuma migração, nenhum endpoint novo, nenhum modelo novo.
- **Dono único da lógica**: módulo novo `App.TaskbarCollections`
  (`app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee`) com a API
  `create`, `addKey`, `removeKey`, `rename`, `toggleCollapsed`, `dissolve`,
  `collectionFor(key)`, `reconcile`, `save`. Dispara `taskbarCollections:change`; o
  widget só consome.

**Ordem — `prio` continua sendo a única fonte.** Membros de Coleção mantêm prios
**contíguos**; a Coleção ancora na posição do primeiro membro. Após qualquer mudança
estrutural, o widget achata a ordem visual (top→bottom, entrando nas Coleções) e chama o
`App.TaskManager.reorder(keys)` existente. Outros clientes (Vue desktop/mobile) seguem
vendo uma lista plana ordenada e coerente.

**Reconciliação** (a Coleção segue as Abas):

- *No init da taskbar*: descartar `keys` sem Aba correspondente; remover Coleções vazias;
  salvar se algo mudou.
- *No fechamento de Aba* (evento `taskRemove` existente): remover a key da Coleção;
  Coleção vazia é removida.
- Edição simultânea em dois dispositivos: último save vence (risco aceito da abordagem B).

## Interação — drag & drop

Cada item tem três zonas de drop:

- **Bordas superior/inferior** (~20% cada): reordenar, comportamento atual.
- **Miolo** (~60% da altura, com destaque visual): sobre Aba Solta **cria Coleção** com
  as duas (input de nome já focado; a Coleção nasce na posição da Aba alvo); sobre
  membro de Coleção **adiciona** àquela Coleção.

Com Coleções existentes:

- O **cabeçalho** segue o mesmo modelo de três zonas para uma Aba arrastada: miolo
  (mesmo recolhido) → entra no **fim** da Coleção; bordas → reordena a Aba **em volta**
  da Coleção.
- Soltar **entre membros** (Coleção expandida) → entra naquela posição.
- Arrastar membro **para fora** → sai da Coleção (esvaziou → some).
- Arrastar o **cabeçalho** → move a Coleção inteira como unidade na lista raiz.
- **Sem aninhamento**: arrastando uma Coleção, o miolo **nunca arma** (nem sobre Aba
  Solta, nem sobre outra Coleção) — Coleção arrastada só reordena.

Implementação: o sortable único atual vira **sortables conectados** (lista raiz + uma
lista interna por Coleção, `connectWith`). A detecção do miolo é feita durante o drag
(posição do ponteiro vs. retângulo do alvo, armando/desarmando o destaque); ao soltar
armado, cancela o sort (`sortable('cancel')`) e chama a ação do `App.TaskbarCollections`.
O bundle jQuery UI 1.11.4 do app já inclui sortable/draggable/droppable — sem lib nova.

## Componentes & renderização

`App.TaskbarWidget` continua `CollectionController`, com renderização em dois níveis:

- **Mudança estrutural** (criar/renomear/recolher/desfazer Coleção, entrada/saída de
  membro, reorder, Aba nova, init) → reconstrói a lista inteira como sequência de
  unidades (Aba Solta | container de Coleção). Barato: a taskbar tem ~30 itens no máximo.
- **Mudança de item** (título, notify, ativa) → replace pontual por item que já existe
  hoje (`renderList`), igual dentro ou fora de Coleção.

Arquivos novos:

- `app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee` — módulo de
  estado.
- `app/assets/javascripts/app/views/widget/task_collection.jst.eco` — container da
  Coleção: cabeçalho (chevron ▸/▾, nome, contador, ⋯ no hover) com estado normal e de
  edição (input inline), + container dos membros.

Toques mínimos em arquivos upstream:

- `task_manager/singleton.coffee` — guard no `tasksAutoCleanup`: pula Abas em Coleção.
- `taskbar_widget.coffee` — sortables conectados, zonas de drop, render em dois níveis.
- `zammad.scss` — bloco novo com as variáveis `--menu-*` (light/dark automáticos;
  `@include dark` só para exceções): cabeçalho, indentação dos membros, destaque de drop,
  rotação do chevron.

Comportamentos de componente:

- Menu ⋯ reaproveita o padrão de dropdown existente no app.
- **Fechar todas as abas**: mesmo caminho de fechamento do × individual, mas com
  **uma confirmação única** quando houver membros com alterações não salvas
  ("3 abas, 1 com alterações não salvas — fechar mesmo assim?").
- **i18n**: strings visíveis pelo sistema de tradução do app, com textos pt-BR
  (Renomear / Desfazer coleção / Fechar todas as abas / Coleção %s / confirmação).

## Comportamento fino

- **Aba ativa em Coleção recolhida**: ativar uma Aba de Coleção recolhida (busca,
  navegação direta) expande a Coleção. Recolher manualmente a Coleção da Aba ativa move
  o destaque de "ativo" para o cabeçalho.
- **Notify em Coleção recolhida**: qualquer membro com bolinha → indicador no cabeçalho.
  Expandida, só o membro mostra (como hoje).
- **Nome padrão**: "Coleção N" com N = menor número livre entre os padrões existentes.
  Renomear para vazio mantém o nome anterior.
- **Coleção de 1 membro pode existir**; a Coleção só morre vazia ou desfeita.
- **Multi-dispositivo**: documento lido no login; mudanças externas aparecem no próximo
  reload. Last-write-wins.
- **Apps Vue/mobile**: sem impacto — veem a lista plana pelo `prio` achatado.

## Testes

- **QUnit** (`test/`, padrão do app legacy): unidade do `App.TaskbarCollections` —
  reconciliação (keys órfãs descartadas, Coleção vazia some), criar/adicionar/remover/
  renomear/desfazer, numeração do nome padrão, achatamento da ordem em prios.
- **Verificação manual** na stack de dev com browser: criar Coleção por drag,
  entrar/sair, renomear, recolher, fechar todas (com e sem alterações pendentes),
  persistência após re-login, proteção contra a limpeza automática.
- **Build**: coffeelint + `assets:precompile` antes do commit final (erro de
  CSS/CoffeeScript quebra o deploy no Coolify).

## Docs

- `docs/taskbar/CONTEXT.md` — glossário do contexto (criado nesta sessão).
- `CONTEXT-MAP.md` na raiz — o repo passou a ter dois contextos (CSAT, Taskbar).
- Entrada no changelog do `.claude/NEWBYTE_WORKFLOW.md` ao final da sessão.

## Fora de escopo

- Coleções aninhadas.
- Coleções persistentes com abas fechadas (pastas/favoritos) — outra feature.
- Qualquer mudança de backend (migração, endpoint, modelo) — a feature é 100% frontend
  legacy + preferências de usuário.
- UI nova (Vue/desktop-view e mobile) — fora do NDesk, como sempre.

## Entrega

- Branch `feat/ticket-grouping` (já criada); PR contra `newbyte-stable` **só quando o
  usuário pedir**; tag `nb.v{next}` no merge (perguntar a versão antes de criar).
