# app/assets/javascripts/app/controllers/ticket_zoom/csat_modal.coffee
class App.TicketZoomCsatModal extends App.ControllerModal
  backdrop:     'static'   # clicar fora não fecha (evita dispensa acidental)
  buttonClose:  true
  buttonCancel: __('Not now')
  buttonSubmit: __('Submit')
  head:         __('Rate this ticket')
  small:        true

  events:
    'click .js-csat-star': 'selectStar'

  constructor: ->
    super
    @ticketId = @ticket.id
    @scores   = {}

  content: ->
    App.view('ticket_zoom/csat_modal')(
      commentMode: App.Config.get('csat_comment') or 'optional'
    )

  selectStar: (e) =>
    e.preventDefault()
    $star     = $(e.currentTarget)
    dimension = $star.attr('data-dimension')
    value     = parseInt($star.attr('data-value'), 10)
    @scores[dimension] = value
    @$(".js-csat-star[data-dimension='#{dimension}']").each ->
      starValue = parseInt($(@).attr('data-value'), 10)
      $(@).toggleClass('is-selected', starValue <= value)
    @$('.js-csat-error').text('')

  onSubmit: =>
    commentMode = App.Config.get('csat_comment') or 'optional'
    comment     = @$('.js-csat-comment').val() or ''

    if !@scores.resolution or !@scores.service
      @$('.js-csat-error').text(App.i18n.translateContent('Please rate both fields.'))
      return
    if commentMode is 'required' and not comment.trim()
      @$('.js-csat-error').text(App.i18n.translateContent('Please add a comment.'))
      return

    App.Ajax.request(
      id:          "csat-#{@ticketId}"
      type:        'POST'
      url:         "#{@apiPath}/csat/ratings"
      data:        JSON.stringify(ticket_id: @ticketId, score_service: @scores.service, score_resolution: @scores.resolution, comment: comment)
      processData: true
      success: (data) =>
        @submitted = true
        @notify(type: 'success', msg: App.i18n.translateContent('Thanks for your feedback!'))
        @close()
      error: (xhr) =>
        @$('.js-csat-error').text(App.i18n.translateContent('Could not save your rating.'))
    )

  # Qualquer fechar-sem-enviar (X, Esc, "Agora não") conta como dispensa, pra que
  # atualizações ao vivo do ticket não reabram o popup.
  onCancel: => @markDismissed()
  onClose:  -> @markDismissed()

  markDismissed: =>
    return if @submitted
    # App.LocalStorage assinatura: set(key, value, user_id) — user_id truthy => chave
    # "personal::<id>::<key>" (escopo por usuário). Mesma assinatura no get (Task 5).
    App.LocalStorage.set("csat_dismissed_ticket_#{@ticketId}", true, App.User.current()?.id)
