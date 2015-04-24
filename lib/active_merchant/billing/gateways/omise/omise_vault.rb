require 'active_merchant/billing/gateways/omise/omise_core'
module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class OmiseVaultGateway < Gateway
      include OmiseCore
      VAULT_URL = 'https://vault.omise.co/'

      def initialize(options={})
        requires!(options, :public_key)
        @public_key   = options[:public_key]
        self.live_url = VAULT_URL
        super
      end

      # Tokenize a Card.
      #
      # ==== Parameters
      #
      # * <tt>payment</tt> -- The CreditCard.
      # * <tt>options</tt> -- A standard hash options.

      def tokenize(payment, options={})
        options[:key] ||= @public_key
        data = {}
        add_creditcard(data, payment)
        options[:url_endpoint] = self.live_url + 'tokens'
        response = https_request(:post, nil, data, options)
        if successful?(response)
          Response.new(true, nil, token: response)
        else
          Response.new(false, message_from(response), {}, error_code: STANDARD_ERROR_CODE_MAPPING[error_code_from(response)])
        end
      end

    end
  end
end
