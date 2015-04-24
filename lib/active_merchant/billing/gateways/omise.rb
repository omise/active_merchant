require 'active_merchant/billing/rails'
require 'active_merchant/billing/gateways/omise/omise_core'
require 'active_merchant/billing/gateways/omise/omise_vault'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class OmiseGateway < Gateway
      include OmiseCore

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

      def omise_tokenize(creditcard, options={})
        options[:public_key] ||= @public_key
        @vault ||= OmiseVaultGateway.new(options)
        OmisePaymentToken.new(@vault.tokenize(creditcard, options))
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
    end

    class OmisePaymentToken < PaymentToken
      def type
        'omise'
      end
    end

  end
end
