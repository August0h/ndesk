# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

module Nkey
  # ADR-0007: `ZITADEL-Signature: t=<unix>,v1=<hex>[,v1=<hex>]` where
  # hex = HMAC_SHA256(signing_key, "<unix>.<raw body>"). Reject |now - t| > 300s;
  # constant-time compare; accept if ANY v1 matches (key-rotation window).
  module WebhookSignature
    TOLERANCE = 300

    def self.valid?(header:, raw_body:, signing_key:, now: Time.zone.now)
      return false if header.blank? || signing_key.blank?

      timestamp, candidates = parse(header)
      return false if timestamp.blank? || candidates.empty?
      return false if (now.to_i - timestamp.to_i).abs > TOLERANCE

      expected = OpenSSL::HMAC.hexdigest('SHA256', signing_key, "#{timestamp}.#{raw_body}")
      candidates.any? { |candidate| secure_match?(candidate, expected) }
    end

    # Parse the header into `[unix_timestamp, [v1_hex, ...]]`; a missing or
    # non-numeric `t=` yields `[nil, []]` so the caller fails closed.
    def self.parse(header)
      parts      = header.split(',').map(&:strip)
      timestamp  = parts.find { |p| p.start_with?('t=') }&.delete_prefix('t=')
      candidates = parts.select { |p| p.start_with?('v1=') }.map { |p| p.delete_prefix('v1=').downcase }
      return [nil, []] if timestamp.nil? || timestamp !~ %r{\A\d+\z}

      [timestamp, candidates]
    end
    private_class_method :parse

    def self.secure_match?(candidate, expected)
      candidate.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(candidate, expected)
    end
    private_class_method :secure_match?
  end
end
