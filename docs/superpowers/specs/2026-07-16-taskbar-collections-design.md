# Agrupamento de abas na taskbar (sidebar esquerda) — Design

## Objetivo

Deixar o atendente organizar as **abas abertas** da sidebar esquerda (a taskbar da UI
clássica: tickets, usuários, organizações, rascunhos) em **grupos nomeados**, criados por
arrastar-e-soltar: soltar uma aba sobre o miolo de outra cria um grupo; o grupo lista as
abas, pode ser renomeado, recolhido, desagrupado e movido como uma unidade.

## Terminologia

No código, a feature é sempre **`TaskbarGroups`** / **`taskbar_groups`** — nunca "Group"
solto, que no Zammad é o modelo de **departamento** de ticket. Na UI, o texto pt-BR usa
"grupo" normalmente (o contexto da sidebar desambigua).

## Decisões (do brainstorm)

- **O grupo organiza abas abertas** (estilo grupos de abas do Chrome): só contém abas
  vivas da taskbar. Fechar a aba tira do grupo; grupo que esvazia some; aba reaberta
  depois volta **solta**. Rejeitado: pasta persistente que guarda tickets com aba fechada
  (vira outra feature — favoritos/bookmarks).
- **Qualquer tipo de aba pode ser agrupado** (ticket, usuário, organização, rascunho).
  Rejeitado: restringir a tickets (regra por tipo sem ganho real).
- **Nome editável na criação**: ao criar o grupo, o cabeçalho abre com input focado
  (Enter confirma; Esc/blur mantém o padrão "Grupo N"). Renomear depois pelo menu.
  Rejeitados: só nome automático; nome inteligente derivado do cliente/organização.
- **Cabeçalho com menu de contexto (⋯)**: clicar no cabeçalho recolhe/expande; o ⋯ (hover)
  abre menu com **Renomear**, **Desagrupar** e **Fechar todas as abas**. Rejeitados: ×
  minimalista que desagrupa (esconde o "fechar todas"); lápis + × explícitos (sem lugar
  para desagrupar).
- **Abas agrupadas ficam protegidas da limpeza automática** (`tasksAutoCleanup`): agrupar
  é organização deliberada; só abas soltas são candidatas ao fechamento automático.
- **Persistência: documento único em `user.preferences`** (abordagem B). Rejeitados:
  metadado de grupo no `params` de cada aba (o `params` é repassado ao controller da aba
  pelo upstream — contaminá-lo é frágil; rename regravaria N abas); tabela
  `taskbar_groups` de primeira classe (migração + modelo + policy + controller + Spine
  model, e toca a tabela `taskbars` do upstream — esforço e superfície de conflito
  desproporcionais para organização visual per-user).

## Modelo de dados & persistência

Uma chave nova nas preferências do usuário:

```coffee
user.preferences.taskbar_groups = [
  { id: 'g-a1b2c3', name: 'Projeto ERP', collapsed: false,
    keys: ['Ticket-67005', 'Ticket-67022', 'Ticket-67010'] }
]
```

- `id` gerado no cliente (timestamp + aleatório), estável para rename/collapse.
- `keys` = keys da taskbar (`Ticket-123`, `User-45`…), na ordem interna do grupo.
- Save com debounce via `PUT /api/v1/users/preferences` (endpoint existente). Nenhuma
  migração, nenhum endpoint novo, nenhum modelo novo.
- **Dono único da lógica**: módulo novo `App.TaskbarGroups`
  (`app/assets/javascripts/app/lib/app_post/taskbar_groups.coffee`) com a API `create`,
  `addKey`, `removeKey`, `rename`, `toggleCollapsed`, `ungroup`, `groupFor(key)`,
  `reconcile`, `save`. Dispara `taskbarGroups:change`; o widget só consome.

**Ordem — `prio` continua sendo a única fonte.** Membros de grupo mantêm prios
**contíguos**; o grupo ancora na posição do primeiro membro. Após qualquer mudança
estrutural, o widget achata a ordem visual (top→bottom, entrando nos grupos) e chama o
`App.TaskManager.reorder(keys)` existente. Outros clientes (Vue desktop/mobile) seguem
vendo uma lista plana ordenada e coerente.

**Reconciliação** (grupo segue as abas):

- *No init da taskbar*: descartar `keys` sem aba correspondente; remover grupos vazios;
  salvar se algo mudou.
- *No fechamento de aba* (evento `taskRemove` existente): remover a key do grupo; grupo
  vazio é removido.
- Edição simultânea em dois dispositivos: último save vence (risco aceito da abordagem B).

## Interação — drag & drop

Cada item tem três zonas de drop:

- **Bordas superior/inferior** (~20% cada): reordenar, comportamento atual.
- **Miolo** (~60% da altura, com destaque visual): **agrupar** — sobre aba solta cria
  grupo com as duas (input de nome já focado; o grupo nasce na posição da aba alvo);
  sobre membro de grupo adiciona àquele grupo.

Com grupos existentes:

- O **cabeçalho** segue o mesmo modelo de três zonas para uma aba arrastada: miolo
  (mesmo recolhido) → entra no **fim** do grupo; bordas → reordena a aba **em volta** do
  grupo.
- Soltar **entre membros** (grupo expandido) → entra naquela posição.
- Arrastar membro **para fora** → sai do grupo (grupo esvaziou → some).
- Arrastar o **cabeçalho** → move o grupo inteiro como unidade na lista raiz.
- **Sem aninhamento**: arrastando um grupo, o miolo **nunca arma** (nem sobre aba solta,
  nem sobre outro grupo) — grupo arrastado só reordena.

Implementação: o sortable único atual vira **sortables conectados** (lista raiz + uma
lista interna por grupo, `connectWith`). A detecção do miolo é feita durante o drag
(posição do ponteiro vs. retângulo do alvo, armando/desarmando o destaque); ao soltar
armado, cancela o sort (`sortable('cancel')`) e chama a ação do `App.TaskbarGroups`.
O bundle jQuery UI 1.11.4 do app já inclui sortable/draggable/droppable — sem lib nova.

## Componentes & renderização

`App.TaskbarWidget` continua `CollectionController`, com renderização em dois níveis:

- **Mudança estrutural** (criar/renomear/recolher/desagrupar, entrada/saída de membro,
  reorder, aba nova, init) → reconstrói a lista inteira como sequência de unidades
  (aba solta | container de grupo). Barato: a taskbar tem ~30 itens no máximo.
- **Mudança de item** (título, notify, ativa) → replace pontual por item que já existe
  hoje (`renderList`), igual dentro ou fora de grupo.

Arquivos novos:

- `app/assets/javascripts/app/lib/app_post/taskbar_groups.coffee` — módulo de estado.
- `app/assets/javascripts/app/views/widget/task_group.jst.eco` — container do grupo:
  cabeçalho (chevron ▸/▾, nome, contador, ⋯ no hover) com estado normal e de edição
  (input inline), + container dos membros.

Toques mínimos em arquivos upstream:

- `task_manager/singleton.coffee` — guard no `tasksAutoCleanup`: pula abas agrupadas.
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
  (Renomear / Desagrupar / Fechar todas as abas / Grupo %s / confirmação).

## Comportamento fino

- **Aba ativa em grupo recolhido**: ativar uma aba de grupo recolhido (busca, navegação
  direta) expande o grupo. Recolher manualmente o grupo da aba ativa move o destaque de
  "ativo" para o cabeçalho.
- **Notify em grupo recolhido**: qualquer membro com bolinha → indicador no cabeçalho.
  Expandido, só o membro mostra (como hoje).
- **Nome padrão**: "Grupo N" com N = menor número livre entre os padrões existentes.
  Renomear para vazio mantém o nome anterior.
- **Grupo de 1 membro pode existir**; o grupo só morre vazio ou desagrupado.
- **Multi-dispositivo**: documento lido no login; mudanças externas aparecem no próximo
  reload. Last-write-wins.
- **Apps Vue/mobile**: sem impacto — veem a lista plana pelo `prio` achatado.

## Testes

- **QUnit** (`test/`, padrão do app legacy): unidade do `App.TaskbarGroups` —
  reconciliação (keys órfãs descartadas, grupo vazio some), criar/adicionar/remover/
  renomear/desagrupar, numeração do nome padrão, achatamento da ordem em prios.
- **Verificação manual** na stack de dev com browser: criar grupo por drag, entrar/sair,
  renomear, recolher, fechar todas (com e sem alterações pendentes), persistência após
  re-login, proteção contra a limpeza automática.
- **Build**: coffeelint + `assets:precompile` antes do commit final (erro de
  CSS/CoffeeScript quebra o deploy no Coolify).

## Fora de escopo

- Grupos aninhados.
- Grupos persistentes com abas fechadas (pastas/favoritos) — outra feature.
- Qualquer mudança de backend (migração, endpoint, modelo) — a feature é 100% frontend
  legacy + preferências de usuário.
- UI nova (Vue/desktop-view e mobile) — fora do NDesk, como sempre.

## Entrega

- Branch `feat/ticket-grouping` (já criada); PR contra `newbyte-stable` **só quando o
  usuário pedir**; tag `nb.v{next}` no merge (perguntar a versão antes de criar).
- Entrada no changelog do `.claude/NEWBYTE_WORKFLOW.md` ao final da sessão.
