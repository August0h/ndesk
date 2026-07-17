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
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w1') })
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
      // higiene: solta o widget e zera o TaskManager para não vazar handlers
      // nem registros App.Taskbar para os próximos testes
      widget.releaseController()
      App.TaskManager.reset()
      done()
    }, 200)
  }, 300)
})

QUnit.test('fechar aba de coleção remove do documento; coleção vazia some do DOM', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content2"></div><div id="taskbar-w2" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content2'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w2') })
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
        widget.releaseController()
        App.TaskManager.reset()
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
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w2b') })
  App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  App.TaskManager.reset()
  assert.equal(App.TaskbarCollections.all().length, 1, 'documento intacto após reset')
  assert.equal($('#taskbar-w2b .js-collection').length, 0, 'nada renderizado (sem abas vivas)')
  widget.releaseController()
})

// regressão (review): navigation.render() destrói/recria o widget a cada
// ui:rerender — o widget novo precisa semear lastActiveKey, senão o primeiro
// taskUpdate da aba JÁ ativa é lido como transição e re-expande Coleção
// recolhida de propósito
QUnit.test('widget recém-criado não auto-expande em update da aba já ativa', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content4"></div><div id="taskbar-w4" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content4'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  App.TaskManager.execute({ key: 'Y1', controller: 'TestController1', params: {}, show: true, persistent: false })
  App.TaskManager.execute({ key: 'Y2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const c = App.TaskbarCollections.create(['Y1', 'Y2'])
    App.TaskbarCollections.toggleCollapsed(c.id) // usuário recolheu de propósito
    const widget = new App.TaskbarWidget({ el: $('#taskbar-w4') }) // recriação pós-rerender
    assert.ok($('#taskbar-w4 .js-collection').hasClass('is-collapsed'), 'começa recolhida')

    App.TaskManager.touch('Y1') // update de metadados da aba já ativa
    setTimeout(() => {
      assert.ok($('#taskbar-w4 .js-collection').hasClass('is-collapsed'), 'update da aba já ativa não re-expande')
      assert.ok(App.TaskbarCollections.get(c.id).collapsed, 'collapsed persiste no documento')
      widget.releaseController()
      App.TaskManager.reset()
      done()
    }, 200)
  }, 300)
})

// ===== Task 5: menu da coleção =====

QUnit.module('TaskbarWidget: menu da coleção')

QUnit.test('renomear inline: Enter confirma, Esc mantém, vazio mantém', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content3"></div><div id="taskbar-w3" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content3'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w3') })
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
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

QUnit.test('desfazer coleção: abas voltam soltas, nada fecha', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content4"></div><div id="taskbar-w4" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content4'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w4') })
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
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

QUnit.test('fechar todas sem alterações pendentes: fecha direto, sem modal', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content5"></div><div id="taskbar-w5" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content5'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w5') })
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
      widget.releaseController()
      App.TaskManager.reset()
      done()
    }, 300)
  }, 300)
})

QUnit.test('renomear por focusout: perder o foco confirma', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content6"></div><div id="taskbar-w6" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content6'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w6') })
  App.TaskManager.execute({ key: 'N1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'N2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const c = App.TaskbarCollections.create(['N1', 'N2'])
    $('#taskbar-w6 .js-collection-menu-toggle').trigger('click')
    $('#taskbar-w6 .js-collection-rename').trigger('click')
    $('#taskbar-w6 .js-collection-name-input').val('Contábil')
    $('#taskbar-w6 .js-collection-name-input').trigger('focusout')
    assert.equal(App.TaskbarCollections.get(c.id).name, 'Contábil', 'focusout confirma')
    assert.equal($('#taskbar-w6 .js-collection-name').text(), 'Contábil', 'DOM atualizado')
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

QUnit.test('clique no documento fecha o menu aberto', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content7"></div><div id="taskbar-w7" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content7'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w7') })
  App.TaskManager.execute({ key: 'K1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'K2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    App.TaskbarCollections.create(['K1', 'K2'])
    $('#taskbar-w7 .js-collection-menu-toggle').trigger('click')
    assert.notOk($('#taskbar-w7 .js-collection-menu').hasClass('hide'), 'menu aberto')
    $(document).trigger('click')
    assert.ok($('#taskbar-w7 .js-collection-menu').hasClass('hide'), 'clique fora fecha')
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

QUnit.test('fechar todas com aba ativa; guard de key morta no closeKeys', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content8"></div><div id="taskbar-w8" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content8'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-w8') })
  App.TaskManager.execute({ key: 'CA1', controller: 'TestController1', params: {}, show: true, persistent: false })
  App.TaskManager.execute({ key: 'CA2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    App.TaskbarCollections.create(['CA1', 'CA2'])
    $('#taskbar-w8 .js-collection-menu-toggle').trigger('click')
    $('#taskbar-w8 .js-collection-close-all').trigger('click')
    setTimeout(() => {
      assert.notOk(App.TaskManager.get('CA1'), 'aba ativa fechada')
      assert.notOk(App.TaskManager.get('CA2'), 'aba inativa fechada')
      assert.equal(App.TaskbarCollections.all().length, 0, 'coleção morreu')

      // guard de key morta: taskRemove reconcilia o documento SINCRONAMENTE, então
      // o caminho de UI nunca vê key morta — quem vê é o Discard do modal, que
      // guarda um snapshot de keys de quando abriu. Simula esse caminho direto.
      App.TaskManager.execute({ key: 'CA3', controller: 'TestController1', params: {}, show: false, persistent: false })
      App.TaskManager.execute({ key: 'CA4', controller: 'TestController1', params: {}, show: false, persistent: false })
      setTimeout(() => {
        App.TaskbarCollections.create(['CA3', 'CA4'])
        const staleKeys = ['CA3', 'CA4'] // snapshot como o modal guardaria
        App.TaskManager.remove('CA3')    // membro morre com o "modal aberto"
        widget.closeKeys(staleKeys)      // Discard com snapshot velho: não pode estourar
        assert.notOk(App.TaskManager.get('CA3'), 'key morta ignorada sem exceção')
        assert.notOk(App.TaskManager.get('CA4'), 'sobrevivente fechada mesmo após key morta')
        assert.equal(App.TaskbarCollections.all().length, 0, 'coleção morreu junto')
        widget.releaseController()
        App.TaskManager.reset()
        done()
      }, 200)
    }, 200)
  }, 300)
})

// ===== Task 6: drag & drop =====

QUnit.module('TaskbarWidget: drag & drop')

QUnit.test('dndDropOn: miolo de aba solta cria coleção na posição do alvo', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content6dnd"></div><div id="taskbar-wd6" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content6dnd'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-wd6') })
  App.TaskManager.execute({ key: 'G1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'G2', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'G3', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'G4', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    widget.dndDropOn($('#taskbar-wd6 a[data-key=G2]'), $('#taskbar-wd6 a[data-key=G4]'))

    const c = App.TaskbarCollections.collectionFor('G2')
    assert.ok(c, 'coleção criada')
    assert.deepEqual(c.keys, ['G2', 'G4'], 'alvo primeiro, arrastada depois')
    assert.notOk($('#taskbar-wd6 .js-collection-name-input').hasClass('hide'), 'edição de nome já aberta')

    const flat = _.map(App.TaskManager.all(), task => task.key)
    assert.deepEqual(flat, ['G1', 'G2', 'G4', 'G3'], 'prios achatados: coleção ancora na posição do alvo')

    widget.dndDropOn($('#taskbar-wd6 .js-collection-header'), $('#taskbar-wd6 a[data-key=G1]'))
    assert.deepEqual(App.TaskbarCollections.collectionFor('G1').keys, ['G2', 'G4', 'G1'], 'drop no cabeçalho entra no fim')
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

QUnit.test('drop em cabeçalho recolhido expande; drop em membro adiciona', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content7dnd"></div><div id="taskbar-wd7" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content7dnd'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-wd7') })
  App.TaskManager.execute({ key: 'H1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'H2', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'H3', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'H4', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const c = App.TaskbarCollections.create(['H1', 'H2'])
    App.TaskbarCollections.toggleCollapsed(c.id)

    widget.dndDropOn($('#taskbar-wd7 .js-collection-header'), $('#taskbar-wd7 a[data-key=H3]'))
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['H1', 'H2', 'H3'])
    assert.equal(App.TaskbarCollections.get(c.id).collapsed, false, 'cabeçalho recolhido expandiu no drop')

    widget.dndDropOn($('#taskbar-wd7 .js-collection-items a[data-key=H2]'), $('#taskbar-wd7 > a[data-key=H4]'))
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['H1', 'H2', 'H3', 'H4'], 'miolo de membro adiciona à coleção dele')
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

QUnit.test('dndApplyOrder: membership recomputada do DOM (entrar posicionado / sair / dissolver)', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content8dnd"></div><div id="taskbar-wd8" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content8dnd'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-wd8') })
  App.TaskManager.execute({ key: 'K1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'K2', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'K3', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const c = App.TaskbarCollections.create(['K1', 'K2'])

    // simula o sortable movendo K3 pra dentro, entre K1 e K2
    $('#taskbar-wd8 > a[data-key=K3]').insertAfter($('#taskbar-wd8 .js-collection-items a[data-key=K1]'))
    widget.dndApplyOrder()
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['K1', 'K3', 'K2'], 'entrou na posição do drop')

    // simula arrastar K1 e K3 pra fora
    $('#taskbar-wd8 .js-collection-items a[data-key=K1]').appendTo('#taskbar-wd8')
    widget.dndApplyOrder()
    assert.deepEqual(App.TaskbarCollections.get(c.id).keys, ['K3', 'K2'], 'K1 saiu da coleção')

    $('#taskbar-wd8 .js-collection-items a').appendTo('#taskbar-wd8')
    widget.dndApplyOrder()
    assert.notOk(App.TaskbarCollections.get(c.id), 'coleção esvaziada pelo drag morre')
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

// dndFindTarget é a fonte única das zonas: o dndSort arma por ela E o veto do
// rearrange do sortable (dndPatchIntersect) congela a lista por ela
QUnit.test('dndFindTarget: miolo arma, borda não, coleção arrastada nunca arma', assert => {
  const done = assert.async()
  $('#qunit').append('<div id="tw-content9dnd"></div><div id="taskbar-wd9" class="tasks"></div>')
  App.TaskManager.init({ el: $('#tw-content9dnd'), offlineModus: true, force: true })
  App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  const widget = new App.TaskbarWidget({ el: $('#taskbar-wd9') })
  App.TaskManager.execute({ key: 'Z1', controller: 'TestController1', params: {}, show: false, persistent: false })
  App.TaskManager.execute({ key: 'Z2', controller: 'TestController1', params: {}, show: false, persistent: false })

  setTimeout(() => {
    const target = $('#taskbar-wd9 a[data-key=Z1]')
    const dragged = $('#taskbar-wd9 a[data-key=Z2]')
    const midY = target.offset().top + target.outerHeight() * 0.5
    const edgeY = target.offset().top + target.outerHeight() * 0.05
    assert.equal(widget.dndFindTarget(midY, dragged).data('key'), 'Z1', 'miolo arma o alvo')
    assert.notOk(widget.dndFindTarget(edgeY, dragged), 'borda não arma')

    App.TaskbarCollections.create(['Z1', 'Z2'])
    const container = $('#taskbar-wd9 .js-collection')
    const header = $('#taskbar-wd9 .js-collection-header')
    const headerMidY = header.offset().top + header.outerHeight() * 0.5
    assert.notOk(widget.dndFindTarget(headerMidY, container), 'coleção arrastada nunca arma miolo')
    const member = $('#taskbar-wd9 .js-collection-items a[data-key=Z2]')
    assert.ok(widget.dndFindTarget(headerMidY, member).hasClass('js-collection-header'), 'miolo do cabeçalho arma para abas')
    widget.releaseController()
    App.TaskManager.reset()
    done()
  }, 300)
})

// ===== Task 6 (emenda): invariante de filiação única em create/setKeys =====

QUnit.module('TaskbarCollections: filiação única', {
  beforeEach: () => {
    App.TaskbarCollections.init({ force: true, offline: true, collections: [] })
  },
})

QUnit.test('create rouba a key de outra coleção (e dissolve a esvaziada)', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  const c2 = App.TaskbarCollections.create(['Ticket-1'])
  assert.deepEqual(App.TaskbarCollections.get(c1.id).keys, ['Ticket-2'], 'coleção antiga perdeu a key')
  assert.deepEqual(App.TaskbarCollections.get(c2.id).keys, ['Ticket-1'], 'nova coleção ficou com a key')

  const c3 = App.TaskbarCollections.create(['Ticket-1'])
  assert.notOk(App.TaskbarCollections.get(c2.id), 'coleção esvaziada pelo create dissolve')
  assert.deepEqual(App.TaskbarCollections.get(c3.id).keys, ['Ticket-1'])
})

QUnit.test('setKeys rouba a key de outra coleção', assert => {
  const c1 = App.TaskbarCollections.create(['Ticket-1', 'Ticket-2'])
  const c2 = App.TaskbarCollections.create(['Ticket-9'])
  App.TaskbarCollections.setKeys(c2.id, ['Ticket-1', 'Ticket-9'])
  assert.deepEqual(App.TaskbarCollections.get(c1.id).keys, ['Ticket-2'], 'c1 perdeu Ticket-1')
  assert.deepEqual(App.TaskbarCollections.get(c2.id).keys, ['Ticket-1', 'Ticket-9'], 'c2 ganhou na posição pedida')
})

}
