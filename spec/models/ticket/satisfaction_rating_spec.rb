# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Ticket::SatisfactionRating, type: :model do
  subject(:rating) { create(:ticket_satisfaction_rating, ticket:, customer:) }

  let(:agent)    { create(:agent, groups: [group]) }
  let(:group)    { create(:group) }
  let(:customer) { create(:customer) }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent) }

  describe 'associations' do
    # NOTE: the model marks ticket_id/customer_id/agent_id/score_service/score_resolution as attr_readonly.
    # Under Rails' load_defaults 8.0, assigning a readonly attribute on a *persisted*
    # record raises ActiveRecord::ReadonlyAttributeError. The shoulda-matchers
    # belong_to matcher mutates the FK to probe the association, so it must run
    # against a *new* (unpersisted) record where readonly assignment is allowed.
    subject { described_class.new }

    it { is_expected.to belong_to(:ticket) }
    it { is_expected.to belong_to(:customer).class_name('User') }
    it { is_expected.to belong_to(:agent).class_name('User').optional }
    it { is_expected.to belong_to(:group).optional }
  end

  describe 'validations' do
    it 'requires a service score' do
      expect(build(:ticket_satisfaction_rating, score_service: nil)).not_to be_valid
    end

    it 'rejects a service score outside 1..5' do
      expect(build(:ticket_satisfaction_rating, score_service: 6)).not_to be_valid
    end

    it 'requires a resolution score on create' do
      expect(build(:ticket_satisfaction_rating, score_resolution: nil)).not_to be_valid
    end

    it 'rejects a resolution score outside 1..5' do
      expect(build(:ticket_satisfaction_rating, score_resolution: 0)).not_to be_valid
    end

    it 'keeps legacy rows (without resolution score) valid outside the create context' do
      legacy = create(:ticket_satisfaction_rating, :legacy, ticket:, customer:)
      expect(legacy.reload).to be_valid
    end

    it 'forbids a second rating for the same ticket+customer' do
      rating
      dup = build(:ticket_satisfaction_rating, ticket:, customer:)
      expect(dup).not_to be_valid
    end
  end

  describe 'immutability (attr_readonly)' do
    subject(:rating) { create(:ticket_satisfaction_rating, ticket:, customer:, score_service: 3, score_resolution: 4) }

    # Under load_defaults 8.0, assigning a readonly attribute on a persisted
    # record raises rather than silently ignoring the change.
    it 'does not persist a changed service score' do
      aggregate_failures do
        expect { rating.update(score_service: 1) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
        expect(rating.reload.score_service).to eq(3)
      end
    end

    it 'does not persist a changed resolution score' do
      aggregate_failures do
        expect { rating.update(score_resolution: 1) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
        expect(rating.reload.score_resolution).to eq(4)
      end
    end
  end

  describe '#snapshot_agent_and_group (before_create)' do
    it 'captures the ticket owner as agent' do
      expect(rating.agent_id).to eq(agent.id)
    end

    it 'captures the ticket group' do
      expect(rating.group_id).to eq(group.id)
    end

    context 'when the ticket has no real owner' do
      let(:ticket) { create(:ticket, group:, customer:, owner_id: 1) }

      it 'falls back to the last human owner from history' do
        ticket.update!(owner: agent)   # writes a History owner change
        ticket.update!(owner_id: 1)    # unassign again
        expect(rating.agent_id).to eq(agent.id)
      end
    end

    context 'with multiple human owners reassigned out of id order' do
      let(:ticket) { create(:ticket, group:, customer:, owner_id: 1) }

      it 'returns the most recently assigned human owner, not the highest id' do
        earlier = create(:agent, groups: [group]) # lower id
        latest  = create(:agent, groups: [group]) # higher id
        ticket.update!(owner: latest)             # assign higher-id FIRST
        ticket.update!(owner: earlier)            # assign lower-id LAST (most recent)
        ticket.update!(owner_id: 1)               # unassign
        expect(rating.agent_id).to eq(earlier.id)
      end
    end
  end

  describe '.ratable?' do
    let(:group)    { create(:group) }
    let(:agent)    { create(:agent, groups: [group]) }
    let(:customer) { create(:customer) }
    let(:state)    { Ticket::State.find_by(name: 'closed') }
    let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

    before { Setting.set('csat_integration', true) }

    it 'is true for the customer of a closed, unrated ticket' do
      expect(described_class.ratable?(ticket:, user: customer)).to be(true)
    end

    it 'is false when CSAT is disabled' do
      Setting.set('csat_integration', false)
      expect(described_class.ratable?(ticket:, user: customer)).to be(false)
    end

    it 'is false for a non-customer' do
      expect(described_class.ratable?(ticket:, user: agent)).to be(false)
    end

    it 'is false when the ticket is not finalized' do
      ticket.update!(state: Ticket::State.find_by(name: 'open'))
      expect(described_class.ratable?(ticket:, user: customer)).to be(false)
    end

    it 'is false when already rated' do
      create(:ticket_satisfaction_rating, ticket:, customer:)
      expect(described_class.ratable?(ticket:, user: customer)).to be(false)
    end

    it 'is false when user is nil' do
      expect(described_class.ratable?(ticket:, user: nil)).to be(false)
    end
  end
end
