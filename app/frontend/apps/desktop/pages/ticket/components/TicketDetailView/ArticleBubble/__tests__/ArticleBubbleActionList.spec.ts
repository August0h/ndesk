// Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

import { computed } from 'vue'

import { renderComponent } from '#tests/support/components/index.ts'

import { createDummyArticle } from '#shared/entities/ticket-article/__tests__/mocks/ticket-articles.ts'
import { createDummyTicket } from '#shared/entities/ticket-article/__tests__/mocks/ticket.ts'
import { EnumTicketArticleSenderName } from '#shared/graphql/types.ts'
import { convertToGraphQLId } from '#shared/graphql/utils.ts'

import { provideTicketInformationMocks } from '#desktop/entities/ticket/__tests__/mocks/provideTicketInformationMocks.ts'
import ArticleBubbleActionList from '#desktop/pages/ticket/components/TicketDetailView/ArticleBubble/ArticleBubbleActionList.vue'

const renderArticleBubbleActionList = (options?: {
  position?: 'left' | 'right'
  articleOverrides?: Parameters<typeof createDummyArticle>[0]
  provideOverrides?: Parameters<typeof provideTicketInformationMocks>[1]
  withGroupEmail?: boolean
}) => {
  const {
    position = 'left',
    articleOverrides,
    provideOverrides,
    withGroupEmail = true,
  } = options || {}

  return renderComponent(
    {
      components: {
        ArticleBubbleActionList,
      },
      setup() {
        const article = createDummyArticle({
          senderName: EnumTicketArticleSenderName.Agent,
          articleType: 'email',
          attachmentsWithoutInline: [
            {
              id: convertToGraphQLId('Store', 123),
              preferences: {
                'original-format': true,
              },
              internalId: 123,
              name: 'test.txt',
            },
          ],
          ...articleOverrides,
        })

        const ticket = createDummyTicket({
          group: {
            emailAddress: withGroupEmail
              ? {
                  emailAddress: 'support@example.com',
                  name: 'Support',
                }
              : null,
          },
        })

        provideTicketInformationMocks(ticket, provideOverrides)

        return { position, article }
      },
      template: `<div class="relative"><ArticleBubbleActionList :position="position" :article="article"/> </div>`,
    },
    { router: true, store: true },
  )
}

describe('ArticleBubbleActionList', () => {
  it('does not show top level actions on hover (js-dom limitation)', () => {
    const wrapper = renderArticleBubbleActionList()

    expect(wrapper.queryByTestId('top-level-article-action-container')).not.toBeInTheDocument()
  })

  it('has no reply action for email articles', async () => {
    const wrapper = renderArticleBubbleActionList()

    expect(wrapper.queryByRole('button', { name: 'Reply' })).not.toBeInTheDocument()
  })

  it('shows no email popover actions', async () => {
    const wrapper = renderArticleBubbleActionList()

    expect(wrapper.queryByRole('menuitem', { name: 'Forward' })).not.toBeInTheDocument()
    expect(wrapper.queryByRole('menuitem', { name: 'Download original email' })).not.toBeInTheDocument()
    expect(wrapper.queryByRole('menuitem', { name: 'Download raw email' })).not.toBeInTheDocument()
  })

  it('does not show reply all when single recipient', async () => {
    const wrapper = renderArticleBubbleActionList({})

    expect(wrapper.queryByRole('button', { name: 'Reply all' })).not.toBeInTheDocument()
  })

  it('shows no popover actions when original email unavailable', async () => {
    const wrapper = renderArticleBubbleActionList({
      articleOverrides: { attachmentsWithoutInline: [] },
    })

    expect(wrapper.queryByRole('menuitem', { name: 'Forward' })).not.toBeInTheDocument()
    expect(wrapper.queryByRole('menuitem', { name: 'Download raw email' })).not.toBeInTheDocument()
    expect(wrapper.queryByRole('menuitem', { name: 'Download original email' })).not.toBeInTheDocument()
  })

  it('renders right-position actions with reversed order class', () => {
    const wrapper = renderArticleBubbleActionList({ position: 'right' })

    expect(wrapper.queryByTestId('top-level-article-action-container')).not.toBeInTheDocument()
  })

  it('does not render actions when ticket is not editable', () => {
    const wrapper = renderArticleBubbleActionList({
      provideOverrides: { isTicketEditable: computed(() => false) },
    })

    expect(wrapper.queryByTestId('top-level-article-action-container')).not.toBeInTheDocument()
  })
})
