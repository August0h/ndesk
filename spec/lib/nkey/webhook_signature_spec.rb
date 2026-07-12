# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Nkey::WebhookSignature, :aggregate_failures do
  let(:key)  { 'test-signing-key' }
  let(:body) { '{"aggregateID":"u1"}' }
  let(:now)  { Time.zone.now }

  def sign(timestamp, payload, signing = key)
    hex = OpenSSL::HMAC.hexdigest('SHA256', signing, "#{timestamp.to_i}.#{payload}")
    "t=#{timestamp.to_i},v1=#{hex}"
  end

  it 'accepts a valid signature' do
    expect(described_class.valid?(header: sign(now, body), raw_body: body, signing_key: key, now: now)).to be(true)
  end

  it 'rejects a wrong key' do
    expect(described_class.valid?(header: sign(now, body, 'other'), raw_body: body, signing_key: key, now: now)).to be(false)
  end

  it 'rejects a stale timestamp' do
    expect(described_class.valid?(header: sign(now - 301.seconds, body), raw_body: body, signing_key: key, now: now)).to be(false)
  end

  it 'accepts when any v1 matches (rotation window)' do
    good = sign(now, body).split('v1=').last
    header = "t=#{now.to_i},v1=#{'0' * 64},v1=#{good}"
    expect(described_class.valid?(header: header, raw_body: body, signing_key: key, now: now)).to be(true)
  end

  it 'rejects absent or malformed headers' do
    expect(described_class.valid?(header: nil, raw_body: body, signing_key: key, now: now)).to be(false)
    expect(described_class.valid?(header: 'garbage', raw_body: body, signing_key: key, now: now)).to be(false)
  end
end
