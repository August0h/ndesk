class App.TaskbarWidget extends App.CollectionController
  events:
    'click .js-close':                    'remove'
    'click .js-locationVerify':           'location'
    'click .js-collection-header':        'collectionHeaderClick'
    'click .js-collection-menu-toggle':   'collectionMenuToggle'
    'click .js-collection-rename':        'collectionRename'
    'click .js-collection-dissolve':      'collectionDissolve'
    'click .js-collection-close-all':     'collectionCloseAll'
    'keydown .js-collection-name-input':  'collectionNameKeydown'
    'focusout .js-collection-name-input': 'collectionNameFocusout'

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

    # super() rodou a render inicial ANTES do init do módulo; no primeiro boot o
    # documento de Coleções ainda não existia, então a taskbar saiu achatada. Além
    # disso o widget às vezes é construído logo DEPOIS do evento taskbar:init (perde a
    # render de lá). Se já há Coleções carregadas, re-render agora para garantir os dois
    # níveis no F5/relogin. (buildUnits já filtra membros órfãos, então dispensa reconcile.)
    if App.TaskbarCollections.all().length
      @queue.push ['renderAll']
      @uIRunner()

    # seed: navigation.render() destrói/recria o widget a cada ui:rerender — sem
    # o seed, o primeiro taskUpdate da aba já ativa seria lido como transição de
    # ativação e re-expandiria Coleção recolhida de propósito pelo usuário
    @lastActiveKey = _.find(App.TaskManager.all(), (task) -> task.active)?.key

    # Abas que o servidor restaura como ativas no boot (F5/relogin): sua reativação
    # NÃO deve expandir Coleção recolhida (item 7 — recolhimento sobrevive ao reload).
    # App.Taskbar já tem os registros persistidos aqui, antes de o router reativar a
    # aba; em teste offline a lista é vazia, então ativação de usuário expande normal.
    @bootActiveKeys = _.map(_.filter(App.Taskbar.all(), (taskbar) -> taskbar.active), (taskbar) -> taskbar.key)

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
        # restauração de boot: a PRIMEIRA transição de ativação após a construção é a
        # única que pode ser a Aba restaurada como ativa pelo servidor. Se casar com o
        # conjunto, não expande (item 7). Desarma o conjunto SEMPRE nessa primeira
        # transição — mesmo sem casar — senão um ui:rerender de meio de sessão (troca de
        # idioma, prefs, Beta-UI) re-semearia bootActiveKeys e suprimiria erroneamente
        # uma ativação de usuário posterior.
        if @bootActiveKeys.length
          suppress = _.contains(@bootActiveKeys, task.key)
          @bootActiveKeys = []
          continue if suppress
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
    @initDnd()
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
    @dndPatchIntersect(@el)

    innerOptions = _.extend({}, baseOptions, items: '> a')
    inner = @el.find('.js-collection-items')
    inner.sortable(innerOptions)
    inner.each (_i, el) =>
      @dndPatchIntersect($(el))

  # o jQuery UI reposiciona o placeholder (rearrange) ANTES de disparar o sort:
  # a cada entrada vertical do ponteiro o alvo "foge" pro outro lado do
  # placeholder e o miolo nunca fica hoverable com mouse real (verificado com
  # drag real: só entrada horizontal armava). Veto por instância: com o ponteiro
  # no miolo de um alvo válido o sortable não rearranja — o alvo fica parado e o
  # dndSort arma; nas bordas o comportamento original (reordenar) segue intacto.
  dndPatchIntersect: (listEl) =>
    instance = listEl.data('ui-sortable')
    return if !instance
    return if instance.dndZonePatched
    # fail-soft: se um upgrade do jQuery UI remover/renomear o hook interno,
    # o DnD segue sem o veto (perde só a ergonomia do miolo, nada quebra)
    return if !_.isFunction(instance._intersectsWithPointer)
    instance.dndZonePatched = true
    original = instance._intersectsWithPointer
    widget = @
    instance._intersectsWithPointer = (item) ->
      intersection = original.call(@, item)
      return intersection if !intersection
      # fail-soft: sem os internos esperados, devolve o resultado original
      return intersection if !@positionAbs || !@offset?.click
      pointerY = @positionAbs.top + @offset.click.top
      return false if widget.dndFindTarget(pointerY, @currentItem)
      intersection

  dndFindTarget: (pointerY, draggedItem) =>
    return null if draggedItem.hasClass('js-collection')
    draggedKey = draggedItem.data('key')
    target = null
    @el.find('> a, .js-collection-header, .js-collection-items > a').each (_i, el) ->
      $el = $(el)
      return if $el.is(draggedItem)
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
    target

  dndSort: (e, ui) =>
    @dndClearTarget()
    target = @dndFindTarget(e.pageY, ui.item)
    return if !target
    @dndTarget = target
    target.addClass('is-drop-target')

  dndClearTarget: =>
    @dndTarget = null
    @el.find('.is-drop-target').removeClass('is-drop-target')

  dndBeforeStop: (e, ui) =>
    @dndDropTarget = @dndTarget

  dndStop: (e, ui) =>
    # coleção finalizada DENTRO de outra: o _contactContainers do jQuery UI troca
    # de container só por interseção do ponteiro — nunca confere o item arrastado
    # contra o seletor items da lista receptora — e o connectWith liga raiz↔items
    # nos dois sentidos; sem a guarda o dndApplyOrder fundiria as duas coleções
    if ui.item.hasClass('js-collection') && !ui.item.parent().is(@el)
      $(e.target).sortable('cancel')
      @dndDropTarget = null
      @dndClearTarget()
      return
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
        # só filhos diretos: um container aninhado ilegalmente (finalize do
        # jQuery UI sem a guarda do dndStop) não pode ter os membros absorvidos
        $el.find('> .js-collection-items > a').each (_j, member) ->
          key = $(member).data('key')
          return if !key
          membership[id].push key
          keys.push key
          return
      else
        key = $el.data('key')
        keys.push key if key
      return
    for id, memberKeys of membership
      collection = App.TaskbarCollections.get(id)
      continue if !collection
      if !_.isEqual(collection.keys, memberKeys)
        App.TaskbarCollections.setKeys(id, memberKeys)
    App.TaskManager.reorder(keys) if keys.length

  # --- interações da coleção --------------------------------------------------

  collectionHeaderClick: (e) ->
    return if $(e.target).closest('.js-collection-menu, .js-collection-menu-toggle, .js-collection-name-input').get(0)
    e.preventDefault()
    id = $(e.currentTarget).closest('.js-collection').data('id')
    App.TaskbarCollections.toggleCollapsed(id)

  collectionMenuToggle: (e) =>
    e.preventDefault()
    e.stopPropagation()
    menu = $(e.currentTarget).closest('.js-collection-header').find('.js-collection-menu')
    isOpen = !menu.hasClass('hide')
    @el.find('.js-collection-menu').addClass('hide')
    return if isOpen
    menu.removeClass('hide')
    $(document).off('click.taskbarCollectionMenu').one('click.taskbarCollectionMenu', =>
      @el.find('.js-collection-menu').addClass('hide')
    )

  collectionRename: (e) =>
    e.preventDefault()
    e.stopPropagation()
    collectionEl = $(e.currentTarget).closest('.js-collection')
    @el.find('.js-collection-menu').addClass('hide')
    @nameEditStart(collectionEl)

  nameEditStart: (collectionEl) ->
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
      # key pode ter morrido entre o snapshot (modal aberto) e o Discard —
      # removeTask sem guard estoura em currentTask.active e aborta o loop
      continue if !App.TaskManager.get(key)
      @removeTask(key)

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
