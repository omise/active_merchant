require 'test_helper'

class OmiseTest < Test::Unit::TestCase
  def setup
    @gateway = OmiseGateway.new(
      public_key: 'pkey_test_abc',
      secret_key: 'skey_test_123',
    )

    @credit_card = credit_card
    @amount = 3333

    @options = {
      order_id: '1',
      billing_address: address,
      description: 'Store Purchase'
    }

    @card_token = {
      object: 'token',
      id: 'tokn_test_4zgf1crg50rdb68xlk5'
    };
  end

  def test_supported_countries
    assert @gateway.supported_countries == %w( TH )
  end

  def test_supports_scrubbing
    assert @gateway.supports_scrubbing? == true
  end

  def test_scrub
    assert @gateway.scrub(
    <<-RESP
    Authorization: Basic c2tleV90ZXN0XzR6Z2hucDhwM3IzazFhcjZqY206"
    RESP
    ).match(/\[FILTERED\]/)
  end

   def test_gateway_urls
     assert_equal 'https://vault.omise.co/', OmiseVaultGateway::VAULT_URL
     assert_equal 'https://api.omise.co/', OmiseGateway::API_URL
     assert_equal OmiseGateway::API_URL, @gateway.live_url
     assert_equal OmiseVaultGateway::VAULT_URL, OmiseVaultGateway.new(:public_key=>'pkey_test_abc').live_url
   end

  def test_request_headers
    headers = @gateway.send(:headers, { :key => 'pkey_test_555' })
    assert_equal 'Basic cGtleV90ZXN0XzU1NTo=', headers['Authorization']
    assert_equal 'application/json', headers['Content-Type']
  end

  def test_post_data
    post_data = @gateway.send(:post_data, { :card => {:number => '4242424242424242'} })
    assert_equal "{\"card\":{\"number\":\"4242424242424242\"}}", post_data
  end

  def test_parse_response
    response = @gateway.send(:parse, successful_purchase_response)
    assert(response.key?('object'), "expect json response has object key")
  end

  def test_successful_response
    response = @gateway.send(:parse, successful_purchase_response)
    success  = @gateway.send(:successful?, response)
    assert(success, "expect success to be true")
  end

  def test_error_response
    response = @gateway.send(:parse, error_response)
    success  = @gateway.send(:successful?, response)
    assert(!success, "expect success to be false")
  end

  def test_successful_api_request
    @gateway.expects(:ssl_request).returns(successful_list_charges_response)
    response = @gateway.send(:https_request, :get, 'charges')
    assert(!response.empty?)
  end

  def test_message_from_response
    response = @gateway.send(:parse, error_response)
    assert_equal 'failed fraud check', @gateway.send(:message_from, response)
  end

  def test_authorization_from_response
    response = @gateway.send(:parse, successful_purchase_response)
    assert_equal 'chrg_test_4zgf1d2wbstl173k99v', @gateway.send(:authorization_from, response)
  end

  def test_add_creditcard
    result = {}
    @gateway.send(:add_creditcard, result, @credit_card)
    assert_equal @credit_card.number, result[:card][:number]
    assert_equal @credit_card.verification_value, result[:card][:security_code]
    assert_equal 'Longbob Longsen', result[:card][:name]
  end

  def test_add_customer_without_card
    result = {}
    customer_id = 'cust_test_4zjzcgm8kpdt4xdhdw2'
    @gateway.send(:add_customer, result, {:customer_id => customer_id})
    assert_equal nil, result[:customer]
  end

  def test_add_customer_with_token_id
    result = {}
    customer_id   = 'cust_test_4zjzcgm8kpdt4xdhdw2'
    result[:card] = 'tokn_test_4zgf1crg50rdb68xlk5'
    @gateway.send(:add_customer, result, {:customer_id => customer_id})
    assert_equal nil, result[:customer]
  end

  def test_add_customer_with_card_id
    result = {}
    customer_id   = 'cust_test_4zjzcgm8kpdt4xdhdw2'
    result[:card] = 'card_test_4zguktjcxanu3dw171a'
    @gateway.send(:add_customer, result, {:customer_id => customer_id})
    assert_equal customer_id, result[:customer]
  end

  def test_add_token_or_card
    result = {}
    card_id = 'card_test_4zgf1crf975xnz6coa7'
    @gateway.send(:add_token_or_card, result, card_id)
    assert_equal card_id, result[:card]
  end

  def test_add_amount
    result = {}
    desc = 'Charge for order 3947'
    @gateway.send(:add_amount, result, @amount, {:description => desc})
    assert_equal desc, result[:description]
  end

  def test_commit_transaction
    @gateway.expects(:ssl_request).returns(successful_purchase_response)
    response = @gateway.send(:commit, :post, 'charges', {})
    assert_equal 'chrg_test_4zgf1d2wbstl173k99v', response.authorization
  end

  def test_successful_token_exchange
    expect_successful_token_response_object
    tokenized_card = @gateway.send(:omise_tokenize, @credit_card)
    assert_equal 'tokn_test_4zgf1crg50rdb68xlk5', tokenized_card.payment_data.params['token']['id']
  end

  def test_successful_purchase
    expect_successful_token_response_object
    @gateway.expects(:ssl_request).returns(successful_purchase_response)
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'chrg_test_4zgf1d2wbstl173k99v', response.authorization
    assert response.test?
  end

  def test_successful_authorize
    expect_successful_token_response_object
    @gateway.expects(:ssl_request).returns(successful_authorize_response)
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'chrg_test_4zmqak4ccnfut5maxp7', response.authorization
    assert response.test?
    assert response.params['authorized']
  end

  def test_successful_store
    expect_successful_token_response_object
    @gateway.expects(:ssl_request).returns(successful_store_response)
    response = @gateway.store(@credit_card, @options)
    assert_equal 'cust_test_4zkp720zggu4rubgsqb', response.authorization
  end

  def test_successful_capture
    @gateway.expects(:ssl_request).returns(successful_capture_response)
    resp = @gateway.send(:capture, @amount, 'chrg_test_4z5goqdwpjebu1gsmqq')
    assert_equal 'chrg_test_4z5goqdwpjebu1gsmqq', resp.params['id']
  end

  def test_failed_capture
    @gateway.expects(:ssl_request).returns(failed_capture_response)
    resp = @gateway.send(:capture, @amount, 'chrg_test_4z5goqdwpjebu1gsmqq')
    assert_equal 'charge was already captured', resp.message
  end

  def test_successful_refund
    @gateway.expects(:ssl_request).returns(successful_refund_response)
    resp = @gateway.send(:refund, @amount, 'chrg_test_4z5goqdwpjebu1gsmqq')
    assert_equal 'rfnd_test_4zmbpt1zwdsqtmtffw8', resp.params['id']
  end

  def test_successful_partial_refund
    @gateway.expects(:ssl_request).returns(successful_partial_refund_response)
    resp = @gateway.send(:refund, 1000, 'chrg_test_4z5goqdwpjebu1gsmqq')
    assert_equal 1000, resp.params['amount']
  end

  def test_failed_refund
    @gateway.expects(:ssl_request).returns(failed_refund_response)
    resp = @gateway.send(:refund, 9999999, 'chrg_test_4z5goqdwpjebu1gsmqq')
    assert_equal "charge can't be refunded", resp.message
  end

  def test_successful_void
    @gateway.expects(:ssl_request).twice.returns(successful_charge_response, successful_refund_response)
    resp = @gateway.send(:void, 'chrg_test_4z5goqdwpjebu1gsmqq')
    assert_equal 'rfnd_test_4zmbpt1zwdsqtmtffw8', resp.params['id']
  end

  def test_successful_verify
    expect_successful_token_response_object
    @gateway.expects(:ssl_request).at_most(3).returns(successful_authorize_response, successful_refund_response)
    response = @gateway.verify(@credit_card, @options)
    assert_success response
  end

  private

  def error_response
    <<-RESPONSE
    {
      "object": "error",
      "location": "https://docs.omise.co/api/errors#failed-fraud-check",
      "code": "failed_fraud_check",
      "message": "failed fraud check"
    }
    RESPONSE
  end

  def successful_token_exchange
    <<-RESPONSE
    {
      "object": "token",
      "id": "tokn_test_4zgf1crg50rdb68xlk5",
      "livemode": false,
      "location": "https://vault.omise.co/tokens/tokn_test_4zgf1crg50rdb68xlk5",
      "used": false,
      "card": {
        "object": "card",
        "id": "card_test_4zgf1crf975xnz6coa7",
        "livemode": false,
        "country": "us",
        "city": "Bangkok",
        "postal_code": "10320",
        "financing": "",
        "last_digits": "4242",
        "brand": "Visa",
        "expiration_month": 10,
        "expiration_year": 2018,
        "fingerprint": "mKleiBfwp+PoJWB/ipngANuECUmRKjyxROwFW5IO7TM=",
        "name": "Somchai Prasert",
        "security_code_check": true,
        "created": "2015-03-23T05:25:14Z"
      },
      "created": "2015-03-23T05:25:14Z"
    }
    RESPONSE
  end

  def successful_list_charges_response
    <<-RESPONSE
    {
      "object": "list",
      "from": "1970-01-01T00:00:00+00:00",
      "to": "2015-04-01T03:34:11+00:00",
      "offset": 0,
      "limit": 20,
      "total": 1,
      "data": [
        {
          "object": "charge",
          "id": "chrg_test_4zgukttzllzumc25qvd",
          "livemode": false,
          "location": "/charges/chrg_test_4zgukttzllzumc25qvd",
          "amount": 99,
          "currency": "thb",
          "description": "Charge for order 3947",
          "capture": true,
          "authorized": true,
          "captured": true,
          "transaction": "trxn_test_4zguktuecyuo77xgq38",
          "refunded": 0,
          "refunds": {
            "object": "list",
            "from": "1970-01-01T00:00:00+00:00",
            "to": "2015-04-01T03:34:11+00:00",
            "offset": 0,
            "limit": 20,
            "total": 0,
            "data": [

            ],
            "location": "/charges/chrg_test_4zgukttzllzumc25qvd/refunds"
          },
          "failure_code": null,
          "failure_message": null,
          "card": {
            "object": "card",
            "id": "card_test_4zguktjcxanu3dw171a",
            "livemode": false,
            "country": "us",
            "city": "Bangkok",
            "postal_code": "10320",
            "financing": "",
            "last_digits": "4242",
            "brand": "Visa",
            "expiration_month": 2,
            "expiration_year": 2017,
            "fingerprint": "djVaKigLa0g0b12XdGLV8CAdy45FRrOdVsgmv4oze5I=",
            "name": "JOHN DOE",
            "security_code_check": true,
            "created": "2015-03-24T07:54:32Z"
          },
          "customer": null,
          "ip": null,
          "dispute": null,
          "created": "2015-03-24T07:54:33Z"
        }
      ]
    }
    RESPONSE
  end

  def successful_purchase_response
    <<-RESPONSE
    {
      "object": "charge",
      "id": "chrg_test_4zgf1d2wbstl173k99v",
      "livemode": false,
      "location": "/charges/chrg_test_4zgf1d2wbstl173k99v",
      "amount": 100000,
      "currency": "thb",
      "description": null,
      "capture": true,
      "authorized": true,
      "captured": true,
      "transaction": "trxn_test_4zgf1d3f7t9k6gk8hn8",
      "refunded": 0,
      "refunds": {
        "object": "list",
        "from": "1970-01-01T00:00:00+00:00",
        "to": "2015-03-23T05:25:15+00:00",
        "offset": 0,
        "limit": 20,
        "total": 0,
        "data": [

        ],
        "location": "/charges/chrg_test_4zgf1d2wbstl173k99v/refunds"
      },
      "failure_code": null,
      "failure_message": null,
      "card": {
        "object": "card",
        "id": "card_test_4zgf1crf975xnz6coa7",
        "livemode": false,
        "location": "/customers/cust_test_4zgf1cv8e71bbwcww1p/cards/card_test_4zgf1crf975xnz6coa7",
        "country": "us",
        "city": "Bangkok",
        "postal_code": "10320",
        "financing": "",
        "last_digits": "4242",
        "brand": "Visa",
        "expiration_month": 10,
        "expiration_year": 2018,
        "fingerprint": "mKleiBfwp+PoJWB/ipngANuECUmRKjyxROwFW5IO7TM=",
        "name": "Somchai Prasert",
        "security_code_check": true,
        "created": "2015-03-23T05:25:14Z"
      },
      "customer": "cust_test_4zgf1cv8e71bbwcww1p",
      "ip": null,
      "dispute": null,
      "created": "2015-03-23T05:25:15Z"
    }
    RESPONSE
  end

  def successful_store_response
    <<-RESPONSE
    {
      "object": "customer",
      "id": "cust_test_4zkp720zggu4rubgsqb",
      "livemode": false,
      "location": "/customers/cust_test_4zkp720zggu4rubgsqb",
      "default_card": "card_test_4zkp6xeuzurrvacxs2j",
      "email": "john.doe@example.com",
      "description": "John Doe (id: 30)",
      "created": "2015-04-03T04:10:35Z",
      "cards": {
        "object": "list",
        "from": "1970-01-01T00:00:00+00:00",
        "to": "2015-04-03T04:10:35+00:00",
        "offset": 0,
        "limit": 20,
        "total": 1,
        "data": [
          {
            "object": "card",
            "id": "card_test_4zkp6xeuzurrvacxs2j",
            "livemode": false,
            "location": "/customers/cust_test_4zkp720zggu4rubgsqb/cards/card_test_4zkp6xeuzurrvacxs2j",
            "country": "us",
            "city": "Bangkok",
            "postal_code": "10320",
            "financing": "",
            "last_digits": "4242",
            "brand": "Visa",
            "expiration_month": 4,
            "expiration_year": 2017,
            "fingerprint": "djVaKigLa0g0b12XdGLV8CAdy45FRrOdVsgmv4oze5I=",
            "name": "JOHN DOE",
            "security_code_check": false,
            "created": "2015-04-03T04:10:13Z"
          }
        ],
        "location": "/customers/cust_test_4zkp720zggu4rubgsqb/cards"
      }
    }
    RESPONSE
  end

  def successful_charge_response
    <<-RESPONSE
    {
      "object": "charge",
      "id": "chrg_test_4zmqak4ccnfut5maxp7",
      "livemode": false,
      "location": "/charges/chrg_test_4zmqak4ccnfut5maxp7",
      "amount": 100000,
      "currency": "thb",
      "description": null,
      "capture": false,
      "authorized": true,
      "captured": true,
      "transaction": "trxn_test_4zmqf6njyokta57ljs1",
      "refunded": 0,
      "refunds": {
        "object": "list",
        "from": "1970-01-01T00:00:00+00:00",
        "to": "2015-04-08T09:11:39+00:00",
        "offset": 0,
        "limit": 20,
        "total": 0,
        "data": [

        ],
        "location": "/charges/chrg_test_4zmqak4ccnfut5maxp7/refunds"
      },
      "failure_code": null,
      "failure_message": null,
      "card": {
        "object": "card",
        "id": "card_test_4zmqaffhmut87bi075q",
        "livemode": false,
        "country": "us",
        "city": "Bangkok",
        "postal_code": "10320",
        "financing": "",
        "last_digits": "4242",
        "brand": "Visa",
        "expiration_month": 4,
        "expiration_year": 2017,
        "fingerprint": "djVaKigLa0g0b12XdGLV8CAdy45FRrOdVsgmv4oze5I=",
        "name": "JOHN DOE",
        "security_code_check": true,
        "created": "2015-04-08T08:45:40Z"
      },
      "customer": null,
      "ip": null,
      "dispute": null,
      "created": "2015-04-08T08:46:02Z"
    }
    RESPONSE
  end

  def successful_authorize_response
    <<-RESPONSE
    {
      "object": "charge",
      "id": "chrg_test_4zmqak4ccnfut5maxp7",
      "livemode": false,
      "location": "/charges/chrg_test_4zmqak4ccnfut5maxp7",
      "amount": 100000,
      "currency": "thb",
      "description": null,
      "capture": false,
      "authorized": true,
      "captured": false,
      "transaction": null,
      "refunded": 0,
      "refunds": {
        "object": "list",
        "from": "1970-01-01T00:00:00+00:00",
        "to": "2015-04-08T08:46:02+00:00",
        "offset": 0,
        "limit": 20,
        "total": 0,
        "data": [

        ],
        "location": "/charges/chrg_test_4zmqak4ccnfut5maxp7/refunds"
      },
      "failure_code": null,
      "failure_message": null,
      "card": {
        "object": "card",
        "id": "card_test_4zmqaffhmut87bi075q",
        "livemode": false,
        "country": "us",
        "city": "Bangkok",
        "postal_code": "10320",
        "financing": "",
        "last_digits": "4242",
        "brand": "Visa",
        "expiration_month": 4,
        "expiration_year": 2017,
        "fingerprint": "djVaKigLa0g0b12XdGLV8CAdy45FRrOdVsgmv4oze5I=",
        "name": "JOHN DOE",
        "security_code_check": true,
        "created": "2015-04-08T08:45:40Z"
      },
      "customer": null,
      "ip": null,
      "dispute": null,
      "created": "2015-04-08T08:46:02Z"
      }
    RESPONSE
  end

  def successful_capture_response
    <<-RESPONSE
    { "object": "charge",
      "id": "chrg_test_4z5goqdwpjebu1gsmqq",
      "livemode": false,
      "location": "/charges/chrg_test_4z5goqdwpjebu1gsmqq",
      "amount": 100000,
      "currency": "thb",
      "description": "Charge for order 3947",
      "capture": false,
      "authorized": true,
      "captured": true,
      "transaction": "trxn_test_4z5gp0t3mpfsu28u8jo",
      "refunded": 0,
      "refunds": {
        "object": "list",
        "from": "1970-01-01T00:00:00+00:00",
        "to": "2015-02-23T05:16:54+00:00",
        "offset": 0,
        "limit": 20,
        "total": 0,
        "data": [

        ],
        "location": "/charges/chrg_test_4z5goqdwpjebu1gsmqq/refunds"
      },
      "return_uri": "http://www.example.com/orders/3947/complete",
      "reference": "paym_4z5goqdw6rblbxztm4c",
      "authorize_uri": "https://api.omise.co/payments/paym_4z5goqdw6rblbxztm4c/authorize",
      "failure_code": null,
      "failure_message": null,
      "card": {
        "object": "card",
        "id": "card_test_4z5gogdycbrium283yk",
        "livemode": false,
        "country": "us",
        "city": "Bangkok",
        "postal_code": "10320",
        "financing": "",
        "last_digits": "4242",
        "brand": "Visa",
        "expiration_month": 2,
        "expiration_year": 2017,
        "fingerprint": "umrBpbHRuc8vstbcNEZPbnKkIycR/gvI6ivW9AshKCw=",
        "name": "JOHN DOE",
        "security_code_check": true,
        "created": "2015-02-23T05:15:18Z"
      },
      "customer": null,
      "ip": null,
      "created": "2015-02-23T05:16:05Z"
    }
    RESPONSE
  end

  def failed_capture_response
    <<-RESPONSE
    {
      "object": "error",
      "location": "https://docs.omise.co/api/errors#failed-capture",
      "code": "failed_capture",
      "message": "charge was already captured"
    }
    RESPONSE
  end

  def expect_successful_token_response_object
    response = Response.new(true, nil, token: JSON.parse(successful_token_exchange))
    omise_token = OmisePaymentToken.new(response)
    @gateway.expects(:omise_tokenize).returns(omise_token)
  end

  def successful_refund_response
    <<-RESPONSE
    { "object": "refund",
      "id": "rfnd_test_4zmbpt1zwdsqtmtffw8",
      "location": "/charges/chrg_test_4zmbg6gtzz7zhf6rio6/refunds/rfnd_test_4zmbpt1zwdsqtmtffw8",
      "amount": 3333,
      "currency": "thb",
      "charge": "chrg_test_4zmbg6gtzz7zhf6rio6",
      "transaction": "trxn_test_4zmbpt23zmi9acu4qzk",
      "created": "2015-04-07T07:55:21Z"
     }
    RESPONSE
  end

  def successful_partial_refund_response
    <<-RESPONSE
    { "object": "refund",
      "id": "rfnd_test_4zmbpt1zwdsqtmtffw8",
      "location": "/charges/chrg_test_4zmbg6gtzz7zhf6rio6/refunds/rfnd_test_4zmbpt1zwdsqtmtffw8",
      "amount": 1000,
      "currency": "thb",
      "charge": "chrg_test_4zmbg6gtzz7zhf6rio6",
      "transaction": "trxn_test_4zmbpt23zmi9acu4qzk",
      "created": "2015-04-07T07:55:21Z"
     }
    RESPONSE
  end

  def failed_refund_response
    <<-RESPONSE
    { "object": "error",
      "location": "https://docs.omise.co/api/errors#failed-refund",
      "code": "failed_refund",
      "message": "charge can't be refunded"
    }
    RESPONSE
  end

end
