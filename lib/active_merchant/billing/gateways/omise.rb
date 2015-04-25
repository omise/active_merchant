require 'active_merchant/billing/rails'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class OmiseGateway < Gateway
      API_VERSION = '1.0'
      API_URL     = 'https://api.omise.co/'
      VAULT_URL   = 'https://vault.omise.co/'

      STANDARD_ERROR_CODE_MAPPING = {
        'invalid_security_code' => STANDARD_ERROR_CODE[:invalid_cvc]
      }

      self.live_url = self.test_url = API_URL

      # Currency supported by Omise
      # * Thai Baht
      self.default_currency = 'THB'
      # Or, Satang
      self.money_format     = :cents

      #Country supported by Omise
      # * Thailand
      self.supported_countries = %w( TH )

      # Credit cards supported by Omise
      # * VISA
      # * MasterCard
      self.supported_cardtypes = [:visa, :master]

      # Omise main page
      self.homepage_url = 'https://www.omise.co/'
      self.display_name = 'Omise'

      # Creates a new OmiseGateway.
      #
      # Omise requires public_key for token creation.
      # And it requires secret_key for other transactions.
      # These keys can be found in https://dashboard.omise.co/test/api-keys
      #
      # ==== Options
      #
      # * <tt>:public_key</tt> -- Omise's public key (REQUIRED).
      # * <tt>:secret_key</tt> -- Omise's secret key (REQUIRED).

      def initialize(options={})
        requires!(options, :public_key, :secret_key)
        @public_key = options[:public_key]
        @secret_key = options[:secret_key]
        super
      end

      # Perform a purchase.
      #
      # ==== Parameters
      #
      # * <tt>money</tt>   -- The purchasing amount as the value is in Satang.
      # * <tt>payment</tt> -- The CreditCard object or card token that is used for the transaction.
      # * <tt>options</tt> -- An optional parameters.
      #
      # ==== Options
      # * <tt>token_id</tt> -- token id, use Omise.js library to retrieve a token id
      # if this is passed as an option, it will ignore tokenizing via Omisevaultgateway object
      #
      # === Example
      #  To create a charge on a card
      #
      #   purchase(money, creditcard_object)
      #
      #  To create a charge on a token
      #
      #   purchase(money, nil, { :token_id => token_id, ... })
      #
      #  To create a charge on a customer
      #
      #   purchase(money, nil, { :customer_id => customer_id })

      def purchase(money, payment, options={})
        create_post_for_purchase(money, payment, options)
      end

      # Authorize a charge.
      #
      # ==== Parameters
      #
      # * <tt>money</tt>   -- An amount of money to charge in Satang.
      # * <tt>payment</tt> -- The CreditCard
      # * <tt>options</tt> -- A standard hash options

      def authorize(money, payment, options={})
        options[:capture] = 'false'
        create_post_for_purchase(money, payment, options)
      end

      # Capture or a pre-authorized charge.
      #
      # ==== Parameters
      #
      # * <tt>money</tt>     -- An amount of money to charge in Satang.
      # * <tt>charge_id</tt> -- The Charge object identifier.
      # * <tt>options</tt>   -- A standard hash options.

      def capture(money, charge_id, options={})
        post = {}
        add_amount(post, money, options)
        commit(:post, "charges/#{CGI.escape(charge_id)}/capture", post, options)
      end

      # Void a charge.
      #
      # ==== Parameters
      #
      # * <tt>charge_id</tt> -- The Charge object identifier.
      # * <tt>options</tt>   -- A standard hash options.

      def void(charge_id, options={})
        MultiResponse.run(:first) do |r|
          r.process { commit(:get, "charges/#{CGI.escape(charge_id)}") }
          r.process { refund(r.params['amount'], charge_id, options) }
        end.responses.last
      end

      # Refund a charge.
      #
      # ==== Parameters
      #
      # * <tt>money</tt>     -- An amount of money to charge in Satang.
      # * <tt>charge_id</tt> -- The Charge object identifier.
      # * <tt>options</tt>   -- A standard hash options.

      def refund(money, charge_id, options={})
        options[:amount] = money if money
        commit(:post, "charges/#{CGI.escape(charge_id)}/refunds", options)
      end

      # Backward compatible method for refunding a charge.
      def credit(money, charge_id, options={})
        ActiveMerchant.deprecated CREDIT_DEPRECATION_MESSAGE
        refund(money, charge_id, options)
      end

      # Create a Customer and associated Card.
      #
      # ==== Parameters
      #
      # * <tt>payment</tt> -- The CreditCard.
      # * <tt>options</tt> -- A standard hash options.
      # * use options set_default_card: true to set the default card

      def store(payment, options={})
        return Response.new(false, "#{payment.errors.full_messages.join('. ')}") if payment.is_a?(CreditCard) and !payment.valid?
        post, card_params = {}, {}
        add_customer_data(post, options) # add description, email params etc.
        add_or_create_token(card_params, payment, options) # add token or card to params[:card] when it's valid.
        if options[:customer_id] # attach the card to this customer
          attach_customer_card(post, card_params, options)
        else
          commit(:post, 'customers', post.merge(card_params), options)
        end
      end

      # Delete a customer or associated credit card.
      #
      # ==== Parameters
      #
      # * <tt>customer_id</tt> -- The Customer identifier (REQUIRED).
      # * <tt>options</tt>     -- A standard hash options.

      def unstore(customer_id, options={})
        return unless customer_id
        return commit(:delete, "customers/#{CGI.escape(customer_id)}") unless options[:card_id]
        commit(:delete, "customers/#{CGI.escape(customer_id)}/cards/#{CGI.escape(options[:card_id])}")
      end


      # Verify a Card.
      #
      # ==== Parameters
      #
      # * <tt>payment</tt> -- The CreditCard.
      # * <tt>options</tt> -- A standard hash options.

      def verify(payment, options={})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(25, payment, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((Authorization: Basic )\w+), '\1[FILTERED]').
          gsub(%r((card\[number\]=)\d+), '\1[FILTERED]').
          gsub(%r((card\[security_code\]=)\d+), '\1[FILTERED]')
      end

      private

      def vault_tokenize(payment, options={})
        options[:key] ||= @public_key
        data = {}
        add_creditcard(data, payment)
        options[:url_endpoint] = VAULT_URL + 'tokens'
        response = https_request(:post, nil, data, options)
        if successful?(response)
          Response.new(true, nil, token: response)
        else
          Response.new(false, message_from(response), {}, error_code: STANDARD_ERROR_CODE_MAPPING[error_code_from(response)])
        end
      end

      def omise_tokenize(creditcard, options={})
        options[:public_key] ||= @public_key
        OmisePaymentToken.new(vault_tokenize(creditcard, options))
      end

      def add_or_create_token(post, payment, options={})
        if options[:token_id] or (options[:card_id] and options[:customer_id])
          add_token_or_card(post, nil, options) #add token id or card id to post[:card]
        else
          omise_token = omise_tokenize(payment) #try to create token
          response    = omise_token.payment_data
          return response unless response.params.key?('token') #return omise error object.
          add_token_or_card(post, response.params['token']['id'], options)
        end
      end

      def update_customer(customer_id, params, options)
        commit(:patch, "customers/#{CGI.escape(customer_id)}", params, options)
      end

      def attach_customer_card(post, card_params, options)
        customer_id = options[:customer_id]
        MultiResponse.run do |r|
          r.process { update_customer(customer_id, card_params, options) } #attach
          if options[:set_default_card] and r.success? and !r.params['id'].blank?
            post[:default_card] = r.params['cards']['data'].last['id'] #the latest card id
            r.process { update_customer(customer_id, post, options) } if post.count > 0
          end
        end.responses.last
      end

      def create_post_for_purchase(money, payment, options)
        post = {}
        post[:capture] = options[:capture] if options[:capture]
        error_response = add_or_create_token(post, payment, options)
        return error_response if error_response and error_response.is_a?(Response)
        MultiResponse.run do |r|
          r.process do
            add_amount(post, money, options)
            add_customer(post, options)
            commit(:post, 'charges', post)
          end
        end.responses.last
      end

      def headers(options={})
        key = options[:key] || @secret_key
        {
          "Content-Type"  => "application/json",
          "User-Agent"    => "Omise/v#{API_VERSION} ActiveMerchantBindings/#{ActiveMerchant::VERSION}",
          'Authorization' => 'Basic ' + Base64.encode64(key.to_s + ':').strip,
        }
      end

      def post_data(params=nil)
        return nil unless params
        params.to_json
      end

      def https_request(method, endpoint, parameters=nil, options={})
        raw_response = response = nil
        url_endpoint = options[:url_endpoint] || API_URL + endpoint
        begin
          raw_response = ssl_request(method, url_endpoint, post_data(parameters), headers(options))
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = parse(raw_response)
        rescue JSON::ParserError
          response = json_error(raw_response)
        end
        response
      end

      def parse(body)
        JSON.parse(body)
      end

      def json_error(raw_response)
        {
          message: 'Invalid response received from Omise API.  Please contact support@omise.co if you continue to receive this message.' +
            '  (The raw response returned by the API was #{raw_response.inspect})'
        }
      end

      def commit(method, endpoint, params=nil, options={})
        response = https_request(method, endpoint, params, options)
        Response.new(
          successful?(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?,
          error_code: successful?(response) ? nil : STANDARD_ERROR_CODE_MAPPING[error_code_from(response)]
        )
      end

      def error_code_from(response)
        (response['object'] == 'error') ? response['code'] : response['failure_code']
      end

      def message_from(response)
        return 'Success' if successful?(response)
        (response['message'] ? response['message'] : response['failure_message'])
      end

      def authorization_from(response)
        response['id'] if successful?(response)
      end

      def successful?(response)
        ( response.key?('object') and response['object'] != 'error' ) and response['failure_code'].nil?
      end

      def add_creditcard(post, creditcard)
        return if creditcard.nil?
        card = {
          :number           => creditcard.number,
          :name             => creditcard.name,
          :security_code    => creditcard.verification_value,
          :expiration_month => creditcard.month,
          :expiration_year  => creditcard.year
        }
        post[:card] = card
      end

      def add_customer(post, options={})
        return if post[:card].nil? or post[:card].match(/tokn(_test)?_[1-9a-z]+/)
        post[:customer] = options[:customer_id] if post[:card].match(/card(_test)?_[1-9a-z]+/)
      end

      def add_customer_data(post, options={})
        post[:description] = options[:description] if options[:description]
        post[:email]       = options[:email] if options[:email]
      end

      def add_token_or_card(post, token_or_card, options={})
        post[:card] = options[:token_id] || options[:card_id] || token_or_card
      end

      def add_amount(post, money, options)
        post[:amount]      = amount(money)
        post[:currency]    = options[:currency] || currency(money)
        post[:description] = options[:description] if options.key?(:description)
      end

    end #OmiseGateway

    class OmisePaymentToken < PaymentToken
      def type
        'omise'
      end
    end

  end
end
