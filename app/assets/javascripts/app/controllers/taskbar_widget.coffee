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

  collectionHeaderClick: (e) ->
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
