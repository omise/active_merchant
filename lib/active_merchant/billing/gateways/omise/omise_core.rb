require 'JSON'
require 'active_merchant/billing/gateway'
module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    module OmiseCore
      API_VERSION = '1.0'
      API_URL     = 'https://api.omise.co/'

      STANDARD_ERROR_CODE_MAPPING = {
        'invalid_security_code' => Gateway::STANDARD_ERROR_CODE[:invalid_cvc]
      }

      def self.included(base)
        base.live_url = base.test_url = API_URL

        # Currency supported by Omise
        # * Thai Baht
        base.default_currency = 'THB'
        # Or, Satang
        base.money_format     = :cents

        #Country supported by Omise
        # * Thailand
        base.supported_countries = %w( TH )

        # Credit cards supported by Omise
        # * VISA
        # * MasterCard
        base.supported_cardtypes = [:visa, :master]

        # Omise main page
        base.homepage_url = 'https://www.omise.co/'
        base.display_name = 'Omise'
      end

      private

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
        return if post[:card].nil?
        return if post[:card].match(/tokn(_test)?_[1-9a-z]+/)
        post[:customer] = options[:customer_id] if post[:card].match(/card(_test)?_[1-9a-z]+/)
      end

      def add_customer_data(post, options={})
        post[:description] = options[:description] if options[:description]
        post[:email]       = options[:email] if options[:email]
      end

      def add_token_or_card(post, token_or_card, options={})
        post[:card] = options[:token_id] || token_or_card
      end

      def add_amount(post, money, options)
        post[:amount]      = amount(money)
        post[:currency]    = options[:currency] || currency(money)
        post[:description] = options[:description] if options.key?(:description)
      end

    end
  end
end

