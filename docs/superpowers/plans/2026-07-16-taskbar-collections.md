# Coleções de Abas na Taskbar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Atendente organiza as Abas da taskbar (sidebar esquerda da UI clássica) em Coleções nomeadas via drag & drop, persistidas em `user.preferences`.

**Architecture:** Um módulo novo `App.TaskbarCollections` (facade + singleton, espelhando `App.TaskManager`) é o dono único do documento de Coleções; o `App.TaskbarWidget` ganha renderização em dois níveis (rebuild estrutural barato + replace pontual por item) e sortables jQuery UI conectados com detecção de "miolo" para criar/adicionar a Coleções. Zero backend novo: save via `PUT /api/v1/users/preferences` (merge por chave), ordem via `prio` existente da taskbar.

**Tech Stack:** CoffeeScript/Spine (app legacy em `app/assets/javascripts`), templates `.jst.eco`, jQuery UI 1.11.4 (sortable, já bundlado), SCSS (`zammad.scss`), QUnit + sinon (páginas `/tests_<nome>`), i18n via `@T()` + `i18n/zammad.pt-br.po`.

---

## Contexto para quem nunca viu este repo

- **Spec**: `docs/superpowers/specs/2026-07-16-taskbar-collections-design.md`. Glossário: `docs/taskbar/CONTEXT.md` (Taskbar, Aba, Coleção, Aba Solta). ADR: `docs/taskbar/adr/0001-colecoes-em-user-preferences.md`.
- **NUNCA toque** em `app/frontend/` (apps Vue do upstream). Todo o trabalho é no app legacy `app/assets/`.
- **Auto-include**: `app/assets/javascripts/app/index.coffee` faz `require_tree ./lib/app_post`, `./views` e `./controllers` — arquivos novos nessas árvores entram no bundle sem tocar manifesto.
- **Como a taskbar funciona hoje**:
  - `App.TaskManager` (`app/lib/app_post/task_manager.coffee` + `task_manager/singleton.coffee`): estado das Abas (`allTasksByKey`), ordem por `prio` (inteiro), `reorder(keys)` reatribui prios 1..N, persistência REST em `/api/v1/taskbar`. Eventos globais: `taskInit`, `taskUpdate`, `taskRemove`, `taskCollectionOrderSet`.
  - `App.TaskbarWidget` (`app/controllers/taskbar_widget.coffee`): herda `App.CollectionController` (`app/controllers/_application_controller/collection.coffee`), renderiza `widget/task_item.jst.eco` por Aba dentro de `.tasks` (el vindo de `_plugin/navigation.coffee:237`), com `uniqKey: 'key'` e sortable para reordenar.
  - `App.CollectionController` mantém `@renderList` (key → el jQuery); `renderItem(item, el)` faz replace in-place quando `el` é passado; `renderAll` reconstrói tudo.
- **QUnit**: arquivos em `public/assets/tests/qunit/<nome>.js`, servidos em `http://localhost:3000/tests_<nome>` (rotas só em dev/test; layout inclui QUnit + **sinon** automaticamente). Padrão: tudo dentro de `window.onload = function() { ... }`. Precedente: `public/assets/tests/qunit/taskbar.js` roda `App.TaskManager.init({offlineModus: true, force: true})` para testar sem servidor. `App.TestController1` (`app/controllers/test.coffee`) é um worker de teste já existente.
- **Para subir o stack e abrir páginas com browser**: use a skill `verify` deste repo (ela documenta boot, login e drive de browser). Rodar QUnit = abrir a URL da suíte e ler o sumário no topo da página (`N assertions of M passed, X failed`).
- **i18n**: strings de UI em inglês no código via `@T('...')` (templates) / `App.i18n.translateInline('...')` (Coffee) / `__('...')` (marcação estática em classes); traduções pt-BR em `i18n/zammad.pt-br.po` (msgid/msgstr). Precedente CSAT: `app/views/ticket_zoom/csat_modal.jst.eco` + entradas no `.po` (~linha 27820).
- **Estilo**: coffeelint (`coffeelint.json`), 2 espaços, sem parênteses em chamadas com hash multilinha (siga os arquivos vizinhos). CSS usa variáveis `--menu-*` (light/dark automáticos).
- **Commits**: livres na branch `feat/ticket-grouping`. NUNCA commitar/pushar na `newbyte-stable`. Não commitar `.devcontainer/default/devcontainer-lock.json`, `skills-lock.json`, `.claude/skills/`.

## Mapa de arquivos

| Arquivo | Ação | Responsabilidade |
|---|---|---|
| `app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee` | Criar | Estado + persistência do documento de Coleções (dono único) |
| `app/assets/javascripts/app/views/widget/task_collection.jst.eco` | Criar | Container da Coleção (cabeçalho + membros + menu) |
| `app/assets/javascripts/app/controllers/taskbar_widget.coffee` | Modificar | Render em dois níveis, menu, rename inline, DnD |
| `app/assets/javascripts/app/lib/app_post/task_manager/singleton.coffee` | Modificar (1 linha) | Guard da auto-limpeza |
| `app/assets/stylesheets/zammad.scss` | Modificar | Estilos das Coleções (após bloco `.tasks`, ~linha 4849) |
| `i18n/zammad.pt-br.po` | Modificar | Traduções pt-BR |
| `public/assets/tests/qunit/taskbar_collections.js` | Criar | Suíte QUnit da feature |
| `.claude/NEWBYTE_WORKFLOW.md` | Modificar | Entrada de changelog (Task 9) |

---

### Task 1: Módulo `App.TaskbarCollections` (estado, sem persistência)

**Files:**
- Create: `public/assets/tests/qunit/taskbar_collections.js`
- Create: `app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee`

- [ ] **Step 1.1: Escrever os testes QUnit (falhando)**

Criar `public/assets/tests/qunit/taskbar_collections.js`:

```js
window.onload = function() {

// ===== Task 1: estado do módulo =====

QUnit.module('TaskbarCollections: estado', {
  beforeEach: () => {
    App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  },
})

QUnit.test('create gera id, nome padrão e keys', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  assert.ok(/^c-/.test(c1.id), 'id com prefixo c-')
  assert.equal(c1.name, 'Collection 1', 'nome padrão (locale en nos testes)')
  assert.equal(c1.collapsed, false)
  assert.deepEqual(c1.keys, ['Ticket-1', 'Ticket-2'])

  const c2 = App.TaskbarCollections.create(['Ticket-3'])
  assert.equal(c2.name, 'Collection 2', 'numeração incrementa')

  App.TaskbarCollections.rename(c1.id, 'Fiscal')
  const c3 = App.TaskbarCollections.create(['Ticket-4'])
  assert.equal(c3.name, 'Collection 1', 'menor número livre é reutilizado')
})

QUnit.test('get e collectionFor', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  assert.equal(App.TaskbarCollections.get(c1.id).id, c1.id)
  assert.equal(App.TaskbarCollections.collectionFor('Ticket-2').id, c1.id)
  assert.notOk(App.TaskbarCollections.collectionFor('Ticket-99'), 'key fora de coleção')
})

QUnit.test('addKey no fim, em posição, e movendo entre coleções', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  App.TaskbarCollections.addKey(c1.id, 'Ticket-3')
  assert.deepEqual(App.TaskbarCollections.get(c1.id).keys, ['Ticket-1', 'Ticket-2', 'Ticket-3'], 'append no fim')

  App.TaskbarCollections.addKey(c1.id, 'Ticket-0', 0)
  assert.deepEqual(App.TaskbarCollections.get(c1.id).keys, ['Ticket-0', 'Ticket-1', 'Ticket-2', 'Ticket-3'], 'insere na posição')

  const c2 = App.TaskbarCollections.create(['Ticket-9'])
  App.TaskbarCollections.addKey(c2.id, 'Ticket-1')
  assert.deepEqual(App.TaskbarCollections.get(c1.id).keys, ['Ticket-0', 'Ticket-2', 'Ticket-3'], 'saiu da coleção original')
  assert.deepEqual(App.TaskbarCollections.get(c2.id).keys, ['Ticket-9', 'Ticket-1'], 'entrou na nova')

  App.TaskbarCollections.addKey(c2.id, 'Ticket-1', 0)
  assert.deepEqual(App.TaskbarCollections.get(c2.id).keys, ['Ticket-1', 'Ticket-9'], 'reposiciona dentro da mesma coleção')
})

QUnit.test('removeKey e a morte da coleção vazia', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  App.TaskbarCollections.removeKey('Ticket-1')
  assert.deepEqual(App.TaskbarCollections.get(c1.id).keys, ['Ticket-2'], 'coleção de 1 membro pode existir')
  App.TaskbarCollections.removeKey('Ticket-2')
  assert.notOk(App.TaskbarCollections.get(c1.id), 'coleção esvaziou, sumiu')
  App.TaskbarCollections.removeKey('Ticket-2')
  assert.equal(App.TaskbarCollections.all().length, 0, 'removeKey de key inexistente é no-op')
})

QUnit.test('rename valida vazio; toggleCollapsed e expand', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1'])
  App.TaskbarCollections.rename(c1.id, '  Fiscal  ')
  assert.equal(App.TaskbarCollections.get(c1.id).name, 'Fiscal', 'trim aplicado')
  App.TaskbarCollections.rename(c1.id, '   ')
  assert.equal(App.TaskbarCollections.get(c1.id).name, 'Fiscal', 'vazio mantém o nome anterior')

  App.TaskbarCollections.toggleCollapsed(c1.id)
  assert.equal(App.TaskbarCollections.get(c1.id).collapsed, true)
  App.TaskbarCollections.expand(c1.id)
  assert.equal(App.TaskbarCollections.get(c1.id).collapsed, false)
  App.TaskbarCollections.expand(c1.id)
  assert.equal(App.TaskbarCollections.get(c1.id).collapsed, false, 'expand em expandida é no-op')
})

QUnit.test('dissolve e setKeys', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  App.TaskbarCollections.dissolve(c1.id)
  assert.equal(App.TaskbarCollections.all().length, 0, 'dissolve remove a coleção')

  const c2 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2', 'Ticket-3'])
  App.TaskbarCollections.setKeys(c2.id, ['Ticket-3', 'Ticket-1'])
  assert.deepEqual(App.TaskbarCollections.get(c2.id).keys, ['Ticket-3', 'Ticket-1'], 'setKeys substitui ordem/membros')
  App.TaskbarCollections.setKeys(c2.id, [])
  assert.notOk(App.TaskbarCollections.get(c2.id), 'setKeys vazio dissolve')
})

QUnit.test('eventos: mudanças disparam taskbarCollections:change', assert => {
  let count = 0
  const handler = () => count++
  App.Event.bind('taskbarCollections:change', handler)
  const c1 = App.TaskbarCollections.create(['Ticket-1'])
  App.TaskbarCollections.rename(c1.id, 'X')
  App.TaskbarCollections.toggleCollapsed(c1.id)
  App.TaskbarCollections.dissolve(c1.id)
  assert.equal(count, 4, 'create + rename + toggle + dissolve')
  App.Event.unbind('taskbarCollections:change', handler)
})

}
```

- [ ] **Step 1.2: Rodar e ver falhar**

Suba o stack (skill `verify`) e abra `http://localhost:3000/tests_taskbar_collections`.
Esperado: **FALHA** — `App.TaskbarCollections is undefined` (todos os testes quebram).

- [ ] **Step 1.3: Implementar o módulo**

Criar `app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee`:

```coffee
class App.TaskbarCollections
  _instance = undefined

  @init: (params = {}) ->
    if params.force
      _instance = new App.TaskbarCollectionsSingleton(params)
      return
    _instance ?= new App.TaskbarCollectionsSingleton(params)

  @all: ->
    return [] if !_instance
    _instance.all()

  @get: (id) ->
    return if !_instance
    _instance.get(id)

  @collectionFor: (key) ->
    return if !_instance
    _instance.collectionFor(key)

  @create: (keys) ->
    return if !_instance
    _instance.create(keys)

  @addKey: (id, key, position = null) ->
    return if !_instance
    _instance.addKey(id, key, position)

  @removeKey: (key) ->
    return if !_instance
    _instance.removeKey(key)

  @rename: (id, name) ->
    return if !_instance
    _instance.rename(id, name)

  @toggleCollapsed: (id) ->
    return if !_instance
    _instance.toggleCollapsed(id)

  @expand: (id) ->
    return if !_instance
    _instance.expand(id)

  @dissolve: (id) ->
    return if !_instance
    _instance.dissolve(id)

  @setKeys: (id, keys) ->
    return if !_instance
    _instance.setKeys(id, keys)

  @reconcile: (existingKeys) ->
    return if !_instance
    _instance.reconcile(existingKeys)

  @flush: ->
    return if !_instance
    _instance.savePush()

class App.TaskbarCollectionsSingleton
  constructor: (params = {}) ->
    @offline = params.offline || false
    if params.collections isnt undefined
      @collections = params.collections
    else
      @collections = clone(App.Session.get('preferences')?.taskbar_collections) || []

  all: ->
    @collections

  get: (id) =>
    _.find(@collections, (collection) -> collection.id is id)

  collectionFor: (key) =>
    _.find(@collections, (collection) -> _.contains(collection.keys, key))

  create: (keys = []) =>
    collection =
      id:        "c-#{Date.now()}-#{Math.floor(Math.random() * 99999)}"
      name:      @defaultName()
      collapsed: false
      keys:      clone(keys)
    @collections.push collection
    @changed()
    collection

  addKey: (id, key, position = null) =>
    collection = @get(id)
    return if !collection
    if _.contains(collection.keys, key)
      collection.keys = _.without(collection.keys, key)
    else
      @removeKey(key, false)
      collection = @get(id)
      return if !collection
    if position isnt null
      collection.keys.splice(position, 0, key)
    else
      collection.keys.push key
    @changed()

  removeKey: (key, notify = true) =>
    collection = @collectionFor(key)
    return if !collection
    collection.keys = _.without(collection.keys, key)
    if collection.keys.length is 0
      @collections = _.without(@collections, collection)
    @changed() if notify

  rename: (id, name) =>
    collection = @get(id)
    return if !collection
    name = $.trim(name)
    return if name is ''
    collection.name = name
    @changed()

  toggleCollapsed: (id) =>
    collection = @get(id)
    return if !collection
    collection.collapsed = !collection.collapsed
    @changed()

  expand: (id) =>
    collection = @get(id)
    return if !collection
    return if !collection.collapsed
    collection.collapsed = false
    @changed()

  dissolve: (id) =>
    collection = @get(id)
    return if !collection
    @collections = _.without(@collections, collection)
    @changed()

  setKeys: (id, keys) =>
    collection = @get(id)
    return if !collection
    if keys.length is 0
      @collections = _.without(@collections, collection)
    else
      collection.keys = clone(keys)
    @changed()

  reconcile: (existingKeys) =>
    changed = false
    for collection in clone(@collections)
      keys = _.filter(collection.keys, (key) -> _.contains(existingKeys, key))
      if keys.length isnt collection.keys.length
        changed = true
        live = @get(collection.id)
        if keys.length is 0
          @collections = _.without(@collections, live)
        else
          live.keys = keys
    @changed() if changed

  defaultName: =>
    n = 1
    loop
      name = App.i18n.translateInline('Collection %s', n)
      return name if !_.find(@collections, (collection) -> collection.name is name)
      n++

  changed: =>
    App.Event.trigger('taskbarCollections:change')
    @save()

  save: =>
    return if @offline
    App.Delay.set(@savePush, 1000, 'taskbar-collections-save', 'task')

  savePush: =>
    return if @offline
    App.Ajax.request(
      id:          'taskbar_collections_save'
      type:        'PUT'
      url:         "#{App.Config.get('api_path')}/users/preferences"
      data:        JSON.stringify(taskbar_collections: @collections)
      processData: true
    )
```

Notas para o executor:
- `clone()` é helper global do app legacy (usado em `task_manager/singleton.coffee`).
- `App.i18n.translateInline('Collection %s', n)` substitui `%s` — sem tradução carregada (QUnit) retorna `Collection 1`.
- O `reconcile` re-busca a coleção viva por id porque itera sobre um clone.
- NÃO tocar em `App.Session.get('preferences')` — retorna referência direta ao registro
  de `App.User` e o comentário em `session.coffee:8` proíbe mutação. O documento é
  recarregado da sessão no login via `taskbar:init` (Task 4); durante a sessão o
  singleton é a única fonte da verdade.
- O delay do save usa level `'task'` de propósito: `reset()` do logout faz
  `App.Delay.clearLevel('task')` ANTES de qualquer evento, cancelando save pendente —
  logout nunca grava.

- [ ] **Step 1.4: Rodar e ver passar**

Recarregue `http://localhost:3000/tests_taskbar_collections`.
Esperado: **PASS** (0 failed).

- [ ] **Step 1.5: Commit**

```bash
git add app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee public/assets/tests/qunit/taskbar_collections.js
git commit -m "feat(taskbar): módulo App.TaskbarCollections — estado das Coleções de abas"
```

---

### Task 2: Persistência e reconciliação

**Files:**
- Modify: `public/assets/tests/qunit/taskbar_collections.js` (adicionar módulo de testes)
- Modify: `app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee` (já implementado na Task 1 — esta task só valida por teste)

O código de `save`/`savePush`/`reconcile` já entrou na Task 1 (o arquivo é um só); esta task cobre esses caminhos com testes dedicados antes de qualquer uso pelo widget.

- [ ] **Step 2.1: Adicionar os testes (falhando se a Task 1 tiver algo errado)**

Adicionar ao FINAL de `taskbar_collections.js`, ainda dentro do `window.onload`:

```js
// ===== Task 2: persistência e reconciliação =====

QUnit.module('TaskbarCollections: persistência')

QUnit.test('savePush envia PUT /users/preferences com o documento', assert => {
  App.TaskbarCollections.init({ force: true, offline: false, collections: [] })
  const stub = sinon.stub(App.Ajax, 'request')
  const c1 = App.TaskbarCollections.create(['Ticket-1'])
  App.TaskbarCollections.flush()
  assert.ok(stub.called, 'App.Ajax.request chamado')
  const args = stub.lastCall.args[0]
  assert.equal(args.type, 'PUT')
  assert.ok(args.url.indexOf('/users/preferences') > -1, 'endpoint de preferências')
  const payload = JSON.parse(args.data)
  assert.equal(payload.taskbar_collections.length, 1)
  assert.equal(payload.taskbar_collections[0].id, c1.id)
  stub.restore()
})

QUnit.test('offline: flush não dispara Ajax', assert => {
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const stub = sinon.stub(App.Ajax, 'request')
  App.TaskbarCollections.create(['Ticket-1'])
  App.TaskbarCollections.flush()
  assert.notOk(stub.called, 'nenhum request em modo offline')
  stub.restore()
})

QUnit.test('reconcile descarta keys órfãs e mata coleção vazia', assert => {
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2', 'Ticket-3'])
  const c2 = App.TaskbarCollections.create(['Ticket-9'])
  App.TaskbarCollections.reconcile(['Ticket-1', 'Ticket-3', 'Ticket-5'])
  assert.deepEqual(App.TaskbarCollections.get(c1.id).keys, ['Ticket-1', 'Ticket-3'], 'órfã descartada')
  assert.notOk(App.TaskbarCollections.get(c2.id), 'coleção 100% órfã morre')
})

QUnit.test('reconcile sem mudança não dispara evento', assert => {
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  App.TaskbarCollections.create(['Ticket-1'])
  let count = 0
  const handler = () => count++
  App.Event.bind('taskbarCollections:change', handler)
  App.TaskbarCollections.reconcile(['Ticket-1', 'Ticket-2'])
  assert.equal(count, 0, 'nada mudou, nada dispara')
  App.Event.unbind('taskbarCollections:change', handler)
})
```

- [ ] **Step 2.2: Rodar a suíte**

Recarregue `http://localhost:3000/tests_taskbar_collections`.
Esperado: **PASS**. Se `flush`/`reconcile` falharem, corrija o módulo (não os testes).

- [ ] **Step 2.3: Commit**

```bash
git add public/assets/tests/qunit/taskbar_collections.js
git commit -m "test(taskbar): persistência e reconciliação das Coleções"
```

---

### Task 3: Guard da auto-limpeza no TaskManager

**Files:**
- Modify: `app/assets/javascripts/app/lib/app_post/task_manager/singleton.coffee` (método `tasksAutoCleanup`, ~linha 532)
- Modify: `public/assets/tests/qunit/taskbar_collections.js`

- [ ] **Step 3.1: Escrever o teste (falhando)**

Adicionar ao final de `taskbar_collections.js` (dentro do `window.onload`):

```js
// ===== Task 3: auto-limpeza protege abas em Coleção =====

QUnit.module('TaskbarCollections: auto-limpeza')

QUnit.test('abas em coleção sobrevivem à limpeza automática', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="cleanup-content"></div>')
  App.TaskManager.init({ el: $('#cleanup-content'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const maxBefore = App.Config.get('ui_task_mananger_max_task_count')
  App.Config.set('ui_task_mananger_max_task_count', 2)
  App.TaskManager.tasksAutoCleanupDelayTime(100)

  App.TaskManager.execute({ key: 'CleanA', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'CleanB', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'CleanC', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskbarCollections.create(['CleanA', 'CleanB'])

  setTimeout(() => {
    assert.ok(App.TaskManager.get('CleanA'), 'membro de coleção protegido')
    assert.ok(App.TaskManager.get('CleanB'), 'membro de coleção protegido')
    assert.notOk(App.TaskManager.get('CleanC'), 'aba solta mais antiga fechou')
    App.Config.set('ui_task_mananger_max_task_count', maxBefore)
    App.TaskManager.tasksAutoCleanupDelayTime(12000)
    done()
  }, 600)
})
```

- [ ] **Step 3.2: Rodar e ver falhar**

Recarregue a suíte. Esperado: **FALHA** — sem o guard, a limpeza fecha `CleanA` (a mais antiga não-ativa; com `count` de volta a 2 ≤ max ela para aí), quebrando o assert de que `CleanA` sobrevive. Com o guard, ela pula `CleanA`/`CleanB` e fecha `CleanC`.

- [ ] **Step 3.3: Implementar o guard**

Em `app/assets/javascripts/app/lib/app_post/task_manager/singleton.coffee`, no `tasksAutoCleanup`, o loop atual é:

```coffee
      for task in tasks
        if currentTaskCount() > maxTaskCount
          if !task.active
```

Adicionar UMA linha de guard antes do `if !task.active`:

```coffee
      for task in tasks
        if currentTaskCount() > maxTaskCount
          # NDesk: Abas em Coleção são protegidas da limpeza automática
          continue if App.TaskbarCollections.collectionFor(task.key)
          if !task.active
```

- [ ] **Step 3.4: Rodar e ver passar**

Recarregue a suíte. Esperado: **PASS** (incluindo os módulos anteriores).

- [ ] **Step 3.5: Commit**

```bash
git add app/assets/javascripts/app/lib/app_post/task_manager/singleton.coffee public/assets/tests/qunit/taskbar_collections.js
git commit -m "feat(taskbar): limpeza automática pula Abas em Coleção"
```

---

### Task 4: Template da Coleção + renderização em dois níveis

**Files:**
- Create: `app/assets/javascripts/app/views/widget/task_collection.jst.eco`
- Modify: `app/assets/javascripts/app/controllers/taskbar_widget.coffee`
- Modify: `public/assets/tests/qunit/taskbar_collections.js`

Nesta task o drag & drop antigo é **removido temporariamente** (o bloco `dndOptions` do constructor); ele volta completo na Task 6 via `initDnd`. Estado intermediário honesto: sem drag, mas render/recolher/expandir funcionando.

- [ ] **Step 4.1: Escrever os testes do widget (falhando)**

Adicionar ao final de `taskbar_collections.js` (dentro do `window.onload`):

```js
// ===== Task 4: renderização em dois níveis =====

QUnit.module('TaskbarWidget: coleções')

QUnit.test('render, recolher e expansão por ativação', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content"></div><div id="taskbar-w1" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  new App.TaskbarWidget({ el: $('#taskbar-w1') })
  App.TaskManager.execute({ key: 'W1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'W2', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'W3', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    assert.equal($('#taskbar-w1 > a').length, 3, '3 abas soltas no nível raiz')

    App.TaskbarCollections.create(['W1', 'W3'])
    assert.equal($('#taskbar-w1 > .js-collection').length, 1, 'container da coleção')
    assert.equal($('#taskbar-w1 .js-collection-items > a').length, 2, '2 membros dentro')
    assert.equal($('#taskbar-w1 > a').length, 1, 'só W2 solta')
    assert.equal($('#taskbar-w1 .js-collection-name').text(), 'Collection 1')
    assert.equal($('#taskbar-w1 .js-collection-count').text(), '2')
    assert.equal($('#taskbar-w1 .js-collection-items > a').first().data('key'), 'W1', 'ordem da coleção respeitada')

    $('#taskbar-w1 .js-collection-header').trigger('click')
    assert.ok($('#taskbar-w1 .js-collection').hasClass('is-collapsed'), 'clique no cabeçalho recolhe')

    App.TaskManager.execute({ key: 'W3', controller: 'TestController1', params: {}, show: true, persistent: false })
    setTimeout(() => {
      assert.notOk($('#taskbar-w1 .js-collection').hasClass('is-collapsed'), 'ativação de membro expande (persistido)')
      assert.notOk(App.TaskbarCollections.get(App.TaskbarCollections.collectionFor('W3').id).collapsed, 'collapsed=false no documento')
      assert.ok($('#taskbar-w1 .js-collection').hasClass('is-active'), 'cabeçalho reflete membro ativo')
      done()
    }, 200)
  }, 300)
})

QUnit.test('fechar aba de coleção remove do documento; coleção vazia some do DOM', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content2"></div><div id="taskbar-w2" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content2'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  new App.TaskbarWidget({ el: $('#taskbar-w2') })
  App.TaskManager.execute({ key: 'X1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'X2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    App.TaskbarCollections.create(['X1', 'X2'])
    App.TaskManager.remove('X1')
    setTimeout(() => {
      assert.deepEqual(App.TaskbarCollections.collectionFor('X2').keys, ['X2'], 'documento reconciliado no fechamento')
      App.TaskManager.remove('X2')
      setTimeout(() => {
        assert.equal($('#taskbar-w2 .js-collection').length, 0, 'coleção vazia sumiu do DOM')
        assert.equal(App.TaskbarCollections.all().length, 0, 'e do documento')
        done()
      }, 200)
    }, 200)
  }, 300)
})

// regressão: taskInit dispara no reset() do logout com lista vazia — o documento
// NÃO pode ser reconciliado/apagado nesse caminho
QUnit.test('logout (TaskManager.reset) não toca o documento de coleções', assert => {
  $('#qunit').append('<div id="tw-content2b"></div><div id="taskbar-w2b" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content2b'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  new App.TaskbarWidget({ el: $('#taskbar-w2b') })
  App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  App.TaskManager.reset()
  assert.equal(App.TaskbarCollections.all().length, 1, 'documento intacto após reset')
  assert.equal($('#taskbar-w2b .js-collection').length, 0, 'nada renderizado (sem abas vivas)')
})
```

Nota de sequência dos testes: `App.TaskManager.init({force: true})` roda `tasksInitial()`,
que dispara `taskbar:init` — e widgets de testes anteriores (nunca liberados) forçam um
reload do documento a partir da sessão vazia do QUnit. Por isso **todo teste re-inita
`App.TaskbarCollections` DEPOIS do `App.TaskManager.init`**, como os snippets já fazem —
manter essa ordem em testes novos.

- [ ] **Step 4.2: Rodar e ver falhar**

Recarregue a suíte. Esperado: **FALHA** — `.js-collection` nunca aparece (widget ainda renderiza lista plana).

- [ ] **Step 4.3: Criar o template**

Criar `app/assets/javascripts/app/views/widget/task_collection.jst.eco`:

```eco
<div class="task-collection js-collection<% if @collection.collapsed: %> is-collapsed<% end %><% if @active: %> is-active<% end %><% if @notify: %> is-modified<% end %>" data-id="<%- @collection.id %>">
  <div class="task-collection-header js-collection-header" title="<%= @collection.name %>">
    <%- @Icon('arrow-right', 'task-collection-chevron') %>
    <div class="task-collection-name js-collection-name u-textTruncate"><%= @collection.name %></div>
    <input class="task-collection-name-input js-collection-name-input hide" value="<%= @collection.name %>" maxlength="80">
    <div class="task-collection-count"><%= @count %></div>
    <div class="task-collection-menu-toggle js-collection-menu-toggle" title="<%- @Ti('Actions') %>">
      <%- @Icon('overflow-button') %>
    </div>
    <ul class="dropdown-menu dropdown-menu-right task-collection-menu js-collection-menu hide" role="menu">
      <li role="menuitem"><a href="#" class="js-collection-rename"><%- @T('Rename') %></a></li>
      <li role="menuitem"><a href="#" class="js-collection-dissolve"><%- @T('Dissolve collection') %></a></li>
      <li role="menuitem"><a href="#" class="js-collection-close-all"><%- @T('Close all tabs') %></a></li>
    </ul>
  </div>
  <div class="task-collection-items js-collection-items"></div>
</div>
```

(Os ícones `arrow-right` e `overflow-button` existem em `public/assets/images/icons.svg`.)

- [ ] **Step 4.4: Reescrever o `taskbar_widget.coffee` (parte de render)**

Substituir o conteúdo de `app/assets/javascripts/app/controllers/taskbar_widget.coffee` por:

```coffee
class App.TaskbarWidget extends App.CollectionController
  events:
    'click .js-close':                    'remove'
    'click .js-locationVerify':           'location'
    'click .js-collection-header':        'collectionHeaderClick'

  model: false
  template: 'widget/task_item'
  uniqKey: 'key'
  observe:
    meta: true
    active: true
    notify: true

  constructor: ->
    super

    App.TaskbarCollections.init()

    App.Event.bind(
      'Taskbar:destroy'
      (data, event) =>
        task = App.Taskbar.find(data.id)
        return if !task
        return if !task.key

        @removeTask(task.key)
      'Collection::Subscribe::Taskbar'
    )

    # bind to changes
    # taskInit dispara APENAS no reset() do logout (lista vazia) — só re-render,
    # NUNCA reconciliar aqui (reconcile([]) apagaria o documento inteiro)
    @controllerBind('taskInit', =>
      @queue.push ['renderAll']
      @uIRunner()
    )
    # taskbar:init dispara no tasksInitial() do login, com as Abas persistidas já
    # carregadas: recarrega o documento da sessão (força — cobre troca de usuário
    # sem reload de página) e reconcilia
    @controllerBind('taskbar:init', =>
      App.TaskbarCollections.init(force: true)
      App.TaskbarCollections.reconcile(_.map(App.TaskManager.all(), (task) -> task.key))
      @queue.push ['renderAll']
      @uIRunner()
    )
    @controllerBind('taskUpdate', (tasks) =>
      # auto-expand só na TRANSIÇÃO de ativação — updates da Aba já ativa (título,
      # meta) não re-expandem Coleção recolhida manualmente
      for task in tasks when task.active && task.key isnt @lastActiveKey
        @lastActiveKey = task.key
        collection = App.TaskbarCollections.collectionFor(task.key)
        if collection && collection.collapsed
          App.TaskbarCollections.expand(collection.id)
      @queue.push ['change', tasks]
      @uIRunner()
    )
    @controllerBind('taskRemove', (tasks) =>
      for task in tasks
        App.TaskbarCollections.removeKey(task.key)
      @queue.push ['destroy', tasks]
      @uIRunner()
    )
    @controllerBind('taskCollectionOrderSet', (taskKeys) =>
      @collectionOrderSet(taskKeys)
    )
    @controllerBind('taskClose', (tasks) =>
      for task in tasks
        @remove(null, task)
    )
    @controllerBind('taskbarCollections:change', =>
      @queue.push ['renderAll']
      @uIRunner()
    )

  itemGet: (key) ->
    App.TaskManager.get(key)

  itemDestroy: (key) ->
    App.TaskManager.remove(key)

  itemsAll: ->
    App.TaskManager.allWithMeta()

  # --- renderização em dois níveis -------------------------------------------

  buildUnits: (items) ->
    units = []
    seen = {}
    itemsByKey = {}
    itemsByKey[item.key] = item for item in items
    for item in items
      collection = App.TaskbarCollections.collectionFor(item.key)
      if !collection
        units.push { type: 'task', item: item }
        continue
      continue if seen[collection.id]
      seen[collection.id] = true
      members = (itemsByKey[key] for key in collection.keys when itemsByKey[key])
      units.push { type: 'collection', collection: collection, members: members }
    units

  renderAll: =>
    items = @itemsAll()
    for item in items
      @itemAttributesSet(item[@uniqKey], @itemAttributes(item))
    localeEls = []
    for unit in @buildUnits(items)
      if unit.type is 'task'
        localeEls.push @renderItem(unit.item, false)
      else
        localeEls.push @renderCollectionUnit(unit)
    @html localeEls
    @collectionOrderSet()
    @onRenderEnd()

  renderCollectionUnit: (unit) ->
    el = $(App.view('widget/task_collection')(
      collection: unit.collection
      count:      unit.members.length
      active:     _.some(unit.members, (item) -> item.active)
      notify:     _.some(unit.members, (item) -> item.notify)
    ))
    container = el.find('.js-collection-items')
    for item in unit.members
      container.append @renderItem(item, false)
    el

  renderParts: (items) =>
    if _.some(items, (item) => !@renderList[item[@uniqKey]])
      @queue.push ['renderAll']
      @uIRunner()
      return
    for item in items
      @renderItem(item, @renderList[item[@uniqKey]])
    @refreshCollectionHeaders()
    @collectionOrderSet()

  refreshCollectionHeaders: =>
    for collection in App.TaskbarCollections.all()
      el = @el.find(".js-collection[data-id='#{collection.id}']")
      continue if !el.get(0)
      tasks = _.compact(App.TaskManager.get(key) for key in collection.keys)
      el.toggleClass('is-active',   _.some(tasks, (task) -> task.active))
      el.toggleClass('is-modified', _.some(tasks, (task) -> task.notify))

  # --- interações da coleção --------------------------------------------------

  collectionHeaderClick: (e) =>
    return if $(e.target).closest('.js-collection-menu, .js-collection-menu-toggle, .js-collection-name-input').get(0)
    e.preventDefault()
    id = $(e.currentTarget).closest('.js-collection').data('id')
    App.TaskbarCollections.toggleCollapsed(id)

  # --- fechamento de abas (comportamento original) ----------------------------

  location: (e) =>
    return if !$(e.currentTarget).hasClass('is-modified')
    @locationVerify(e)

  remove: (e, key = false, force = false) =>
    e?.preventDefault()
    e?.stopPropagation()
    if !key
      key = $(e.target).parents('a').data('key')
    if !key
      throw 'No such key attributes found for task item'

    # check if input has changed
    worker = App.TaskManager.worker(key)
    if !force && worker && worker.changed
      if worker.changed()
        new Remove(
          key: key
          ui: @
          event: e
        )
        return
    @removeTask(key)

  removeTask: (key = false) =>
    return if !key

    # check if active task is closed
    currentTask    = App.TaskManager.get(key)
    tasks          = App.TaskManager.all()
    activeIsClosed = false
    for task in tasks
      if currentTask.active && task.key is key
        activeIsClosed = true

    # remove task
    App.TaskManager.remove(key)

    # if we do not need to move to an other task
    return if !activeIsClosed

    # get new task url
    nextTaskUrl = App.TaskManager.nextTaskUrl()
    if nextTaskUrl
      @navigate nextTaskUrl
      return

    @navigate '#'

class Remove extends App.ControllerModal
  buttonClose: true
  buttonCancel: true
  buttonSubmit: __('Discard Changes')
  buttonClass: 'btn--danger'
  head: __('Confirmation')

  content: ->
    App.i18n.translateContent('Tab has changed, do you really want to close it?')

  onSubmit: =>
    @close()
    @ui.remove(@event, @key, true)
```

O que mudou vs. o original: `App.TaskbarCollections.init()` no constructor; reload forçado do documento + reconcile no `taskbar:init` (login) — `taskInit` (logout/reset) segue só re-renderizando; auto-expand por transição de ativação (`@lastActiveKey`) no `taskUpdate`; `removeKey` no `taskRemove`; bind de `taskbarCollections:change`; `buildUnits`/`renderAll`/`renderCollectionUnit`/`renderParts`/`refreshCollectionHeaders`/`collectionHeaderClick` novos; bloco `dndOptions`+`@el.sortable` do constructor **removido** (volta na Task 6). `remove`/`removeTask`/`location`/classe `Remove` intocados.

- [ ] **Step 4.5: Rodar e ver passar**

Recarregue a suíte. Esperado: **PASS** em todos os módulos (os das Tasks 1–3 continuam verdes).

- [ ] **Step 4.6: Smoke test manual**

Com o stack de dev (skill `verify`): login, abra 3 tickets, rode no console do browser `App.TaskbarCollections.create([App.TaskManager.all()[0].key, App.TaskManager.all()[1].key])` — a sidebar deve mostrar a Coleção com 2 membros; clique no cabeçalho recolhe/expande. (Sem estilos ainda — feio é esperado; sem drag — esperado até a Task 6.)

- [ ] **Step 4.7: Commit**

```bash
git add app/assets/javascripts/app/views/widget/task_collection.jst.eco app/assets/javascripts/app/controllers/taskbar_widget.coffee public/assets/tests/qunit/taskbar_collections.js
git commit -m "feat(taskbar): renderização em dois níveis — Coleções na taskbar widget"
```

---

### Task 5: Menu ⋯ — renomear inline, desfazer, fechar todas

**Files:**
- Modify: `app/assets/javascripts/app/controllers/taskbar_widget.coffee`
- Modify: `public/assets/tests/qunit/taskbar_collections.js`

- [ ] **Step 5.1: Escrever os testes (falhando)**

Adicionar ao final de `taskbar_collections.js` (dentro do `window.onload`):

```js
// ===== Task 5: menu da coleção =====

QUnit.module('TaskbarWidget: menu da coleção')

QUnit.test('renomear inline: Enter confirma, Esc mantém, vazio mantém', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content3"></div><div id="taskbar-w3" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content3'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  new App.TaskbarWidget({ el: $('#taskbar-w3') })
  App.TaskManager.execute({ key: 'M1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'M2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const c = App.TaskbarCollections.create(['M1', 'M2'])

    $('#taskbar-w3 .js-collection-menu-toggle').trigger('click')
    assert.notOk($('#taskbar-w3 .js-collection-menu').hasClass('hide'), 'menu abre')

    $('#taskbar-w3 .js-collection-rename').trigger('click')
    assert.notOk($('#taskbar-w3 .js-collection-name-input').hasClass('hide'), 'input visível')

    $('#taskbar-w3 .js-collection-name-input').val('Fiscal')
    $('#taskbar-w3 .js-collection-name-input').trigger($.Event('keydown', { keyCode: 13 }))
    assert.equal(App.TaskbarCollections.get(c.id).name, 'Fiscal', 'Enter confirma')
    assert.equal($('#taskbar-w3 .js-collection-name').text(), 'Fiscal', 'DOM atualizado')

    $('#taskbar-w3 .js-collection-menu-toggle').trigger('click')
    $('#taskbar-w3 .js-collection-rename').trigger('click')
    $('#taskbar-w3 .js-collection-name-input').val('Outra coisa')
    $('#taskbar-w3 .js-collection-name-input').trigger($.Event('keydown', { keyCode: 27 }))
    assert.equal(App.TaskbarCollections.get(c.id).name, 'Fiscal', 'Esc descarta')

    $('#taskbar-w3 .js-collection-menu-toggle').trigger('click')
    $('#taskbar-w3 .js-collection-rename').trigger('click')
    $('#taskbar-w3 .js-collection-name-input').val('   ')
    $('#taskbar-w3 .js-collection-name-input').trigger($.Event('keydown', { keyCode: 13 }))
    assert.equal(App.TaskbarCollections.get(c.id).name, 'Fiscal', 'vazio mantém')
    done()
  }, 300)
})

QUnit.test('desfazer coleção: abas voltam soltas, nada fecha', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content4"></div><div id="taskbar-w4" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content4'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  new App.TaskbarWidget({ el: $('#taskbar-w4') })
  App.TaskManager.execute({ key: 'D1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'D2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    App.TaskbarCollections.create(['D1', 'D2'])
    $('#taskbar-w4 .js-collection-menu-toggle').trigger('click')
    $('#taskbar-w4 .js-collection-dissolve').trigger('click')
    assert.equal(App.TaskbarCollections.all().length, 0, 'coleção morreu')
    assert.ok(App.TaskManager.get('D1'), 'aba viva')
    assert.ok(App.TaskManager.get('D2'), 'aba viva')
    assert.equal($('#taskbar-w4 > a').length, 2, 'abas soltas no DOM')
    done()
  }, 300)
})

QUnit.test('fechar todas sem alterações pendentes: fecha direto, sem modal', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content5"></div><div id="taskbar-w5" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content5'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  new App.TaskbarWidget({ el: $('#taskbar-w5') })
  App.TaskManager.execute({ key: 'F1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'F2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    App.TaskbarCollections.create(['F1', 'F2'])
    $('#taskbar-w5 .js-collection-menu-toggle').trigger('click')
    $('#taskbar-w5 .js-collection-close-all').trigger('click')
    setTimeout(() => {
      assert.notOk(App.TaskManager.get('F1'), 'F1 fechada')
      assert.notOk(App.TaskManager.get('F2'), 'F2 fechada')
      assert.equal(App.TaskbarCollections.all().length, 0, 'coleção morreu junto')
      done()
    }, 300)
  }, 300)
})
```

- [ ] **Step 5.2: Rodar e ver falhar**

Recarregue a suíte. Esperado: **FALHA** — os handlers do menu não existem (o menu não abre).

- [ ] **Step 5.3: Implementar os handlers**

Em `taskbar_widget.coffee`:

**(a)** Adicionar ao hash `events` da classe:

```coffee
    'click .js-collection-menu-toggle':   'collectionMenuToggle'
    'click .js-collection-rename':        'collectionRename'
    'click .js-collection-dissolve':      'collectionDissolve'
    'click .js-collection-close-all':     'collectionCloseAll'
    'keydown .js-collection-name-input':  'collectionNameKeydown'
    'focusout .js-collection-name-input': 'collectionNameFocusout'
```

**(b)** Adicionar os métodos abaixo, depois de `collectionHeaderClick`:

```coffee
  collectionMenuToggle: (e) =>
    e.preventDefault()
    e.stopPropagation()
    menu = $(e.currentTarget).closest('.js-collection-header').find('.js-collection-menu')
    isOpen = !menu.hasClass('hide')
    @el.find('.js-collection-menu').addClass('hide')
    return if isOpen
    menu.removeClass('hide')
    $(document).one('click.taskbarCollectionMenu', =>
      @el.find('.js-collection-menu').addClass('hide')
    )

  collectionRename: (e) =>
    e.preventDefault()
    e.stopPropagation()
    collectionEl = $(e.currentTarget).closest('.js-collection')
    @el.find('.js-collection-menu').addClass('hide')
    @nameEditStart(collectionEl)

  nameEditStart: (collectionEl) =>
    return if !collectionEl.get(0)
    collectionEl.find('.js-collection-name').addClass('hide')
    input = collectionEl.find('.js-collection-name-input')
    input.removeClass('hide')
    input.trigger('focus')
    input.get(0).select()

  collectionNameKeydown: (e) =>
    if e.keyCode is 13
      e.preventDefault()
      @nameEditCommit($(e.currentTarget))
    else if e.keyCode is 27
      e.preventDefault()
      @nameEditCancel($(e.currentTarget))

  collectionNameFocusout: (e) =>
    input = $(e.currentTarget)
    return if input.hasClass('hide')
    @nameEditCommit(input)

  nameEditCommit: (input) =>
    id = input.closest('.js-collection').data('id')
    input.addClass('hide')
    App.TaskbarCollections.rename(id, input.val())
    @queue.push ['renderAll']
    @uIRunner()

  nameEditCancel: (input) =>
    input.addClass('hide')
    @queue.push ['renderAll']
    @uIRunner()

  collectionDissolve: (e) =>
    e.preventDefault()
    e.stopPropagation()
    id = $(e.currentTarget).closest('.js-collection').data('id')
    @el.find('.js-collection-menu').addClass('hide')
    App.TaskbarCollections.dissolve(id)

  collectionCloseAll: (e) =>
    e.preventDefault()
    e.stopPropagation()
    id = $(e.currentTarget).closest('.js-collection').data('id')
    @el.find('.js-collection-menu').addClass('hide')
    collection = App.TaskbarCollections.get(id)
    return if !collection
    keys = clone(collection.keys)
    changedCount = 0
    for key in keys
      worker = App.TaskManager.worker(key)
      changedCount++ if worker && worker.changed && worker.changed()
    if changedCount > 0
      new CollectionCloseAll(
        keys:         keys
        changedCount: changedCount
        ui:           @
      )
      return
    @closeKeys(keys)

  closeKeys: (keys) =>
    # Aba ativa por último: as outras morrem antes, e a única navegação resultante
    # aponta para uma Aba sobrevivente (fora da Coleção)
    keys = _.sortBy(keys, (key) -> App.TaskManager.get(key)?.active is true)
    for key in keys
      @removeTask(key)
```

**(c)** Adicionar a modal no final do arquivo, depois da classe `Remove`:

```coffee
class CollectionCloseAll extends App.ControllerModal
  buttonClose: true
  buttonCancel: true
  buttonSubmit: __('Discard Changes')
  buttonClass: 'btn--danger'
  head: __('Confirmation')

  content: ->
    App.i18n.translateContent('%s tabs, %s with unsaved changes — close anyway?', @keys.length, @changedCount)

  onSubmit: =>
    @close()
    @ui.closeKeys(@keys)
```

Notas: o rename usa `rename()` do módulo (que já ignora vazio) e força rebuild para restaurar a view em qualquer caso (inclusive nome inalterado). A modal só aparece quando `changedCount > 0` — o QUnit cobre o caminho sem modal; o caminho com modal é coberto na verificação manual da Task 9 (o `TestController1.changed()` retorna sempre `false`).

- [ ] **Step 5.4: Rodar e ver passar**

Recarregue a suíte. Esperado: **PASS**.

- [ ] **Step 5.5: Commit**

```bash
git add app/assets/javascripts/app/controllers/taskbar_widget.coffee public/assets/tests/qunit/taskbar_collections.js
git commit -m "feat(taskbar): menu da Coleção — renomear inline, desfazer, fechar todas"
```

---

### Task 6: Drag & drop — zonas, criação e ordem

**Files:**
- Modify: `app/assets/javascripts/app/controllers/taskbar_widget.coffee`
- Modify: `public/assets/tests/qunit/taskbar_collections.js`

Semântica (do spec): bordas (~20% sup/inf) reordenam via sortable; miolo (~60%) sobre Aba Solta **cria** Coleção (nome já em edição), sobre membro/cabeçalho **adiciona** (cabeçalho recolhido expande); arrastar membro pra fora remove; Coleção arrastada nunca arma o miolo. Após qualquer drop, a ordem visual é achatada em `App.TaskManager.reorder(keys)` e a membership recomputada do DOM.

- [ ] **Step 6.1: Escrever os testes (falhando)**

Adicionar ao final de `taskbar_collections.js` (dentro do `window.onload`):

```js
// ===== Task 6: drag & drop =====

QUnit.module('TaskbarWidget: drag & drop')

QUnit.test('dndDropOn: miolo de aba solta cria coleção na posição do alvo', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content6"></div><div id="taskbar-w6" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content6'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w6') })
  App.TaskManager.execute({ key: 'G1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'G2', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'G3', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'G4', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    widget.dndDropOn($('#taskbar-w6 a[data-key=G2]'), $('#taskbar-w6 a[data-key=G4]'))

    const c = App.TaskbarCollections.collectionFor('G2')
    assert.ok(c, 'coleção criada')
    assert.deepEqual(c.keys, ['G2', 'G4'], 'alvo primeiro, arrastada depois')
    assert.notOk($('#taskbar-w6 .js-collection-name-input').hasClass('hide'), 'edição de nome já aberta')

    const flat = _.map(App.TaskManager.all(), task => task.key)
    assert.deepEqual(flat, ['G1', 'G2', 'G4', 'G3'], 'prios achatados: coleção ancora na posição do alvo')

    widget.dndDropOn($('#taskbar-w6 .js-collection-header'), $('#taskbar-w6 a[data-key=G1]'))
    assert.deepEqual(App.TaskbarCollections.collectionFor('G1').keys, ['G2', 'G4', 'G1'], 'drop no cabeçalho entra no fim')
    done()
  }, 300)
})

QUnit.test('drop em cabeçalho recolhido expande; drop em membro adiciona', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content7"></div><div id="taskbar-w7" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content7'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w7') })
  App.TaskManager.execute({ key: 'H1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'H2', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'H3', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'H4', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const c = App.TaskbarCollections.create(['H1', 'H2'])
    App.TaskbarCollections.toggleCollapsed(c.id)

    widget.dndDropOn($('#taskbar-w7 .js-collection-header'), $('#taskbar-w7 a[data-key=H3]'))
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['H1', 'H2', 'H3'])
    assert.equal(App.TaskbarCollections.get(c.id).collapsed, false, 'cabeçalho recolhido expandiu no drop')

    widget.dndDropOn($('#taskbar-w7 .js-collection-items a[data-key=H2]'), $('#taskbar-w7 > a[data-key=H4]'))
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['H1', 'H2', 'H3', 'H4'], 'miolo de membro adiciona à coleção dele')
    done()
  }, 300)
})

QUnit.test('dndApplyOrder: membership recomputada do DOM (entrar posicionado / sair / dissolver)', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content8"></div><div id="taskbar-w8" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content8'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w8') })
  App.TaskManager.execute({ key: 'K1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'K2', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'K3', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const c = App.TaskbarCollections.create(['K1', 'K2'])

    // simula o sortable movendo K3 pra dentro, entre K1 e K2
    $('#taskbar-w8 > a[data-key=K3]').insertAfter($('#taskbar-w8 .js-collection-items a[data-key=K1]'))
    widget.dndApplyOrder()
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['K1', 'K3', 'K2'], 'entrou na posição do drop')

    // simula arrastar K1 e K3 pra fora
    $('#taskbar-w8 .js-collection-items a[data-key=K1]').appendTo('#taskbar-w8')
    widget.dndApplyOrder()
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['K3', 'K2'], 'K1 saiu da coleção')

    $('#taskbar-w8 .js-collection-items a').appendTo('#taskbar-w8')
    widget.dndApplyOrder()
    assert.notOk(App.TaskbarCollections.get(c.id), 'coleção esvaziada pelo drag morre')
    done()
  }, 300)
})
```

- [ ] **Step 6.2: Rodar e ver falhar**

Recarregue a suíte. Esperado: **FALHA** — `widget.dndDropOn is not a function`.

- [ ] **Step 6.3: Implementar o DnD**

Em `taskbar_widget.coffee`:

**(a)** No `renderAll`, adicionar `@initDnd()` entre `@collectionOrderSet()` e `@onRenderEnd()`:

```coffee
    @html localeEls
    @collectionOrderSet()
    @initDnd()
    @onRenderEnd()
```

**(b)** Adicionar os métodos abaixo (depois de `refreshCollectionHeaders`):

```coffee
  # --- drag & drop -------------------------------------------------------------

  initDnd: =>
    baseOptions =
      tolerance:            'pointer'
      distance:             15
      opacity:              0.6
      forcePlaceholderSize: true
      connectWith:          '.tasks, .js-collection-items'
      sort:                 @dndSort
      beforeStop:           @dndBeforeStop
      stop:                 @dndStop

    rootOptions = _.extend({}, baseOptions, items: '> a, > .js-collection')
    @el.sortable(rootOptions)

    innerOptions = _.extend({}, baseOptions, items: '> a')
    @el.find('.js-collection-items').sortable(innerOptions)

  dndSort: (e, ui) =>
    @dndClearTarget()
    return if ui.item.hasClass('js-collection')
    pointerY = e.pageY
    draggedKey = ui.item.data('key')
    target = null
    @el.find('> a, .js-collection-header, .js-collection-items > a').each (_i, el) ->
      $el = $(el)
      return if $el.is(ui.item)
      # o placeholder do sortable é um <a> sem data-key que acompanha o ponteiro —
      # armá-lo como alvo cancelaria drops legítimos de borda
      return if $el.hasClass('ui-sortable-placeholder')
      return if $el.data('key') is draggedKey
      offset = $el.offset()
      height = $el.outerHeight()
      if pointerY > offset.top + height * 0.2 && pointerY < offset.top + height * 0.8
        target = $el
        return false
      return
    return if !target
    @dndTarget = target
    target.addClass('is-drop-target')

  dndClearTarget: =>
    @dndTarget = null
    @el.find('.is-drop-target').removeClass('is-drop-target')

  dndBeforeStop: (e, ui) =>
    @dndDropTarget = @dndTarget

  dndStop: (e, ui) =>
    target = @dndDropTarget
    @dndDropTarget = null
    @dndClearTarget()
    if target
      $(e.target).sortable('cancel')
      @dndDropOn(target, ui.item)
      return
    @dndApplyOrder()

  dndDropOn: (target, draggedEl) =>
    draggedKey = draggedEl.data('key')
    return if !draggedKey
    newCollection = null
    if target.hasClass('js-collection-header')
      id = target.closest('.js-collection').data('id')
      App.TaskbarCollections.addKey(id, draggedKey)
      App.TaskbarCollections.expand(id)
    else
      targetKey = target.data('key')
      return if !targetKey || targetKey is draggedKey
      targetCollection = App.TaskbarCollections.collectionFor(targetKey)
      if targetCollection
        App.TaskbarCollections.addKey(targetCollection.id, draggedKey)
      else
        newCollection = App.TaskbarCollections.create([targetKey, draggedKey])
    @dndApplyOrder()
    if newCollection
      el = @el.find(".js-collection[data-id='#{newCollection.id}']")
      @nameEditStart(el)

  dndApplyOrder: =>
    keys = []
    membership = {}
    @el.find('> a, > .js-collection').each (_i, el) ->
      $el = $(el)
      if $el.hasClass('js-collection')
        id = $el.data('id')
        membership[id] = []
        $el.find('.js-collection-items > a').each (_j, member) ->
          key = $(member).data('key')
          membership[id].push key
          keys.push key
          return
      else
        keys.push $el.data('key')
      return
    for id, memberKeys of membership
      collection = App.TaskbarCollections.get(id)
      continue if !collection
      if !_.isEqual(collection.keys, memberKeys)
        App.TaskbarCollections.setKeys(id, memberKeys)
    App.TaskManager.reorder(keys) if keys.length
```

Notas para o executor:
- Os rebuilds disparados por `addKey`/`create`/`setKeys` são **síncronos** (evento → `uIRunner`), então depois de `@dndApplyOrder()` o DOM já está normalizado e o `nameEditStart` encontra o container novo.
- `sortable('cancel')` dentro do `stop` reverte o movimento do sortable — quem materializa o resultado do drop de miolo é o rebuild.
- **Watch-item (Step 6.5)**: o rebuild síncrono roda ainda dentro do callback `stop` do
  sortable, substituindo o DOM antes do cleanup interno do jQuery UI. Se aparecer erro
  do sortable no console durante o drag real, manter o `cancel` síncrono e deferir o
  resto (`_.defer => @dndDropOn(...)` / `_.defer @dndApplyOrder`).
- `reorder` grava prios com update mudo (sem re-render), então o input de nome aberto sobrevive.
- O `renderParts`/`refreshCollectionHeaders` não interagem com o DnD.

- [ ] **Step 6.4: Rodar e ver passar**

Recarregue a suíte. Esperado: **PASS** em tudo.

- [ ] **Step 6.5: Verificação manual do drag real**

Com o stack de dev (skill `verify`), teste com mouse: criar Coleção soltando aba no miolo de outra (destaque azul deve aparecer — ainda sem estilo bonito, a classe `is-drop-target` pode ser conferida no inspector); reordenar pelas bordas continua funcionando; arrastar membro pra fora; arrastar o container da Coleção; soltar aba em cabeçalho recolhido (expande).

- [ ] **Step 6.6: Commit**

```bash
git add app/assets/javascripts/app/controllers/taskbar_widget.coffee public/assets/tests/qunit/taskbar_collections.js
git commit -m "feat(taskbar): drag & drop — miolo cria/adiciona à Coleção, bordas reordenam"
```

---

### Task 7: Estilos (SCSS)

**Files:**
- Modify: `app/assets/stylesheets/zammad.scss` (inserir após o bloco `.tasks { ... }`, ~linha 4849)

- [ ] **Step 7.1: Adicionar os estilos**

Inserir logo após o fechamento do bloco `.tasks { ... }`:

```scss
// NDesk: Coleções de abas na taskbar (docs/taskbar/CONTEXT.md)
.task-collection {
  margin: 1px 6px;
  border-radius: 4px;

  &.is-collapsed {
    .task-collection-chevron {
      transform: rotate(0deg);
    }

    .task-collection-items {
      display: none;
    }
  }

  // destaque no cabeçalho só quando recolhida — expandida, quem destaca é o membro
  &.is-collapsed.is-active .task-collection-header {
    background: var(--menu-background-active);
    color: var(--menu-text-active);
  }

  &.is-collapsed.is-modified .task-collection-name:after {
    content: '';
    display: inline-block;
    width: 6px;
    height: 6px;
    margin-left: 6px;
    border-radius: 50%;
    background: var(--menu-text-active);
  }
}

.task-collection-header {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 10px;
  cursor: pointer;
  position: relative;
  color: var(--menu-text);
  font-weight: 600;
  border-radius: 4px;

  &:hover {
    background: var(--menu-background-primary-hover);
  }

  .task-collection-chevron {
    width: 8px;
    height: 8px;
    flex-shrink: 0;
    fill: currentColor;
    transform: rotate(90deg);
    transition: transform 150ms ease;
  }
}

.task-collection-name {
  flex: 1;
  min-width: 0;
}

.task-collection-name-input {
  flex: 1;
  min-width: 0;
  background: var(--menu-background-primary);
  color: var(--menu-text);
  border: var(--menu-border-secondary);
  border-radius: 3px;
  padding: 2px 6px;
  font: inherit;
}

.task-collection-count {
  font-weight: 400;
  font-size: 11px;
  color: var(--menu-icon);
}

.task-collection-menu-toggle {
  visibility: hidden;
  cursor: pointer;

  .icon {
    width: 16px;
    height: 16px;
    fill: var(--menu-icon);
  }
}

.task-collection-header:hover .task-collection-menu-toggle {
  visibility: visible;
}

.task-collection-menu {
  position: absolute;
  top: 100%;
  right: 6px;
  z-index: 100;

  &:not(.hide) {
    display: block;
  }
}

.task-collection-items {
  margin-left: 14px;
  border-left: var(--menu-border-secondary);
  min-height: 2px;
}

.tasks .is-drop-target {
  box-shadow: inset 0 0 0 2px var(--menu-background-active);
  border-radius: 4px;
  // mesma matiz de --button-primary-background (hsl(203, 65%, 55%)) com alpha —
  // var() não carrega canal alpha e o wash translúcido funciona nos dois temas
  background: hsla(203, 65%, 55%, 0.15);
}
```

Regras do repo: só variáveis `--menu-*` (light/dark automáticos — o NDesk tem sidebar clara no light mode); **não** usar `url(#id)` em SVG (Safari); o `.hide` é utilitário global.

**Atenção**: `--menu-border` e `--menu-border-secondary` são shorthands **completos** de
borda (valem `none` em vários temas) — nunca usar dentro de `1px solid var(...)`. No
tema dark `--menu-border-secondary: none`, então a linha de indentação dos membros some
(consistente com o design sem bordas do dark); a indentação por `margin-left` permanece.

- [ ] **Step 7.2: Conferir visual nos dois temas**

Stack de dev (skill `verify`): conferir sidebar em light e dark — cabeçalho, hover, chevron girando, contador, menu ⋯, indentação dos membros, destaque azul durante drag, bolinha de modificado com Coleção recolhida.

- [ ] **Step 7.3: Commit**

```bash
git add app/assets/stylesheets/zammad.scss
git commit -m "feat(taskbar): estilos das Coleções — cabeçalho, membros, drop target"
```

---

### Task 8: i18n pt-BR

**Files:**
- Modify: `i18n/zammad.pt-br.po`

- [ ] **Step 8.1: Verificar quais msgids já existem**

```bash
for s in "Rename" "Dissolve collection" "Close all tabs" "Collection %s" "%s tabs, %s with unsaved changes — close anyway?" "Actions"; do
  printf '%s => ' "$s"; grep -c "msgid \"$s\"" i18n/zammad.pt-br.po; done
```

`Rename` e `Actions` normalmente já existem (upstream); adicionar apenas os que retornarem `0`.

- [ ] **Step 8.2: Adicionar as traduções que faltam**

Junto às entradas do CSAT (~linha 27820 de `i18n/zammad.pt-br.po`), no mesmo formato:

```po
msgid "Collection %s"
msgstr "Coleção %s"

msgid "Dissolve collection"
msgstr "Desfazer coleção"

msgid "Close all tabs"
msgstr "Fechar todas as abas"

msgid "%s tabs, %s with unsaved changes — close anyway?"
msgstr "%s abas, %s com alterações não salvas — fechar mesmo assim?"
```

- [ ] **Step 8.3: Sincronizar e conferir**

As traduções entram no banco via `Translation.sync` (ex.: `bundle exec rails runner 'Translation.sync'` — se o bundler estiver quebrado neste ambiente, use o método de boot da skill `verify`, que documenta o contorno). Depois, com usuário em pt-BR: menu deve mostrar "Renomear / Desfazer coleção / Fechar todas as abas" e o nome padrão "Coleção 1".

- [ ] **Step 8.4: Commit**

```bash
git add i18n/zammad.pt-br.po
git commit -m "feat(taskbar): traduções pt-BR das Coleções"
```

---

### Task 9: Lint, build, verificação ponta-a-ponta e changelog

**Files:**
- Modify: `.claude/NEWBYTE_WORKFLOW.md` (changelog)

- [ ] **Step 9.1: Lint**

```bash
pnpm exec coffeelint -f coffeelint.json app/assets/javascripts/app/lib/app_post/taskbar_collections.coffee app/assets/javascripts/app/controllers/taskbar_widget.coffee app/assets/javascripts/app/lib/app_post/task_manager/singleton.coffee
```

Esperado: `0 errors and 0 warnings`. (Se `pnpm exec` não encontrar o binário, `npx coffeelint@^2` com os mesmos argumentos.)

- [ ] **Step 9.2: Build de assets**

O deploy roda `assets:precompile` (Sprockets) — erro de CoffeeScript/SCSS quebra o deploy. Rodar o precompile (ou o equivalente documentado na skill `verify`, dado o bundler quebrado do ambiente) e confirmar que termina sem erro.

- [ ] **Step 9.3: Suíte QUnit completa**

Abrir `http://localhost:3000/tests_taskbar_collections` e também `http://localhost:3000/tests_taskbar` (regressão da taskbar upstream). Esperado: **0 failed** nas duas.

- [ ] **Step 9.4: QA manual (roteiro do spec)**

Com a skill `verify` (dois browsers se possível — Chromium e WebKit):

1. Criar Coleção soltando aba no miolo de outra → input de nome focado; Enter confirma; Esc mantém "Coleção 1".
2. Adicionar: drop no cabeçalho (expandido e recolhido — recolhido expande), drop entre membros (entra na posição), miolo de membro.
3. Remover: arrastar membro pra fora; fechar aba com × (sai do documento); esvaziar → Coleção some.
4. Menu ⋯: renomear; desfazer (abas voltam soltas); fechar todas — com uma aba contendo rascunho de resposta digitado, a modal única aparece com a contagem.
5. Recolher/expandir; ativar membro por busca com Coleção recolhida → expande e persiste.
6. Reordenar: bordas de abas soltas, arrastar o container da Coleção; Coleção sobre Coleção só reordena.
7. Persistência: F5 e re-login → Coleções, nomes, ordem e collapsed intactos. Incluir
   o ciclo **logout → login sem F5** (SPA não recarrega a página): Coleções intactas —
   regressão do bug de `reconcile([])` no logout. Se possível, logar com um segundo
   usuário no mesmo browser e conferir que as Coleções do primeiro **não vazam**.
8. Auto-limpeza: (console) `App.Config.set('ui_task_mananger_max_task_count', 3)` com 4+ abas, 2 em Coleção → só as soltas fecham. Restaurar o valor depois.
9. Vue intocado: abrir `/desktop` → taskbar plana, sem erro de console.

- [ ] **Step 9.5: Changelog da sessão**

Adicionar entrada no changelog de `.claude/NEWBYTE_WORKFLOW.md` (seguir o formato das entradas existentes): data, branch `feat/ticket-grouping`, resumo (Coleções de abas na taskbar — módulo, widget, DnD, estilos, i18n, docs de domínio) e arquivos tocados.

- [ ] **Step 9.6: Commit final**

```bash
git add .claude/NEWBYTE_WORKFLOW.md
git commit -m "docs(workflow): changelog — Coleções de abas na taskbar"
git push
```

---

## Fora do plano (não fazer)

- Aninhamento de Coleções; Coleções persistentes com abas fechadas; qualquer mudança de backend; qualquer toque em `app/frontend/` (Vue). PR só quando o usuário pedir.
