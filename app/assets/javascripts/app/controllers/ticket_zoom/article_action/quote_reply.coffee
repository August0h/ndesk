class QuoteReply
  @action: (actions, ticket, article, ui) ->
    return actions if !ticket.editable()
    return actions if ticket.currentView() is 'customer'

    actions.push {
      name: __('quote')
      type: 'quoteReply'
      icon: 'reply'
      href: '#'
    }
    actions

  @perform: (articleContainer, type, ticket, article, ui) ->
    return true if type isnt 'quoteReply'

    ui.scrollToCompose()

    author = article.from
    if !author
      user = App.User.find(article.origin_by_id || article.created_by_id)
      author = user?.displayName() || ''

    cleanBody = $('<div>').html(article.body)
    cleanBody.find('.quote-reply-embedded').remove()
    cleanBodyHtml = cleanBody.html()

    bodyPreview = App.Utils.html2text(cleanBodyHtml, true)
    if bodyPreview.length > 200
      bodyPreview = bodyPreview.substring(0, 200) + '...'

    App.Event.trigger('ui::ticket::setQuoteReply', {
      ticket_id:  ticket.id
      article_id: article.id
      author:     author
      body:       bodyPreview
      bodyHtml:   cleanBodyHtml
      created_at: article.created_at
    })

    true

App.Config.set('050-QuoteReply', QuoteReply, 'TicketZoomArticleAction')
