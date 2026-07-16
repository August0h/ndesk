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
    return if !existingKeys
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
    App.Delay.clear('taskbar-collections-save', 'task')
    url = "#{App.Config.get('api_path')}/users/preferences"
    App.Ajax.request(
      id:          'taskbar_collections_save'
      type:        'PUT'
      url:         url
      data:        JSON.stringify(taskbar_collections: @collections)
      processData: true
      error:       (xhr, statusText, error) ->
        App.Log.error('TaskbarCollections', statusText, error, url)
    )
