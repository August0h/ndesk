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
