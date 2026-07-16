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

// ===== Task 2: persistência e reconciliação =====

QUnit.module('TaskbarCollections: persistência', {
  afterEach: () => {
    sinon.restore()
  },
})

QUnit.test('savePush envia PUT /users/preferences com o documento', assert => {
  App.TaskbarCollections.init({ force: true, offline: false, collections: [] })
  const stub = sinon.stub(App.Ajax, 'request')
  const c1 = App.TaskbarCollections.create(['Ticket-1'])
  App.TaskbarCollections.flush()
  assert.ok(stub.called, 'App.Ajax.request chamado')
  const args = stub.lastCall.args[0]
  assert.equal(args.type, 'PUT')
  assert.ok(args.url.indexOf('/users/preferences') > -1, 'endpoint de preferências')
  assert.equal(typeof args.error, 'function', 'error callback presente')
  const payload = JSON.parse(args.data)
  assert.equal(payload.taskbar_collections.length, 1)
  assert.equal(payload.taskbar_collections[0].id, c1.id)
})

QUnit.test('offline: flush não dispara Ajax', assert => {
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const stub = sinon.stub(App.Ajax, 'request')
  App.TaskbarCollections.create(['Ticket-1'])
  App.TaskbarCollections.flush()
  assert.notOk(stub.called, 'nenhum request em modo offline')
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

QUnit.test('reconcile sem argumento é no-op (guard)', assert => {
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  App.TaskbarCollections.create(['Ticket-1'])
  App.TaskbarCollections.reconcile(undefined)
  assert.equal(App.TaskbarCollections.all().length, 1, 'documento intacto')
})

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
    // higiene: execute() cria registros App.Taskbar mesmo em offlineModus — sem
    // reset(), CleanA/CleanB ficam na collection em memória e o tasksInitial()
    // dos testes de widget re-executa essas abas, poluindo as contagens de âncoras
    App.TaskManager.reset()
    done()
  }, 600)
})

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

}
