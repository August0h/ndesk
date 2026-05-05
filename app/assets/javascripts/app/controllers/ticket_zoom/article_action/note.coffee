class Note
  @action: (actions, ticket, article, ui) ->
    return actions if !ticket.editable()
    actions

  @perform: (articleContainer, type, ticket, article, ui) ->
    true

  @articleTypes: (articleTypes, ticket, ui) ->
    return articleTypes if ticket.currentView() is 'agent'

    internal = false
    articleTypes.push {
      name:       __('note')
      icon:       'note'
      attributes: []
      internal:   internal,
      features:   ['attachment']
    }

    articleTypes

App.Config.set('100-Note', Note, 'TicketZoomArticleAction')
