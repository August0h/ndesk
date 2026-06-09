# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Ticket::SatisfactionRatingPolicy do
  subject(:policy) { described_class.new(user, record) }

  let(:group)    { create(:group) }
  let(:customer) { create(:customer) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }
  let(:record)   { build(:ticket_satisfaction_rating, ticket:, customer:) }

  before { Setting.set('csat_integration', true) }

  context 'when the user is the ticket customer, ticket closed, no prior rating' do
    let(:user) { customer }

    it { is_expected.to permit_actions(%i[create]) }
  end

  context 'when CSAT is disabled' do
    let(:user) { customer }

    before { Setting.set('csat_integration', false) }

    it { is_expected.to forbid_actions(%i[create]) }
  end

  context 'when the ticket is not in a closed state' do
    let(:user)  { customer }
    let(:state) { Ticket::State.find_by(name: 'open') }

    it { is_expected.to forbid_actions(%i[create]) }
  end

  context 'when a rating already exists' do
    let(:user) { customer }

    before { create(:ticket_satisfaction_rating, ticket:, customer:) }

    it { is_expected.to forbid_actions(%i[create]) }
  end

  context 'when the user is not the customer' do
    let(:user) { agent }

    it { is_expected.to forbid_actions(%i[create]) }
  end

  describe '#show?' do
    let(:record) { create(:ticket_satisfaction_rating, ticket:, customer:) }

    it 'permits the owning customer' do
      expect(described_class.new(customer, record).show?).to be(true)
    end

    it 'permits a user with csat.read' do
      admin = create(:admin)
      expect(described_class.new(admin, record).show?).to be(true)
    end

    it 'forbids an unrelated agent' do
      expect(described_class.new(agent, record).show?).to be(false)
    end
  end
end
