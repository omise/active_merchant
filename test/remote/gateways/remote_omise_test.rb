require 'test_helper'

class RemoteOmiseTest < Test::Unit::TestCase
  def setup
    @gateway = OmiseGateway.new(fixtures(:omise))
    @amount  = 8888
    @credit_card   = credit_card('4242424242424242')
    @declined_card = credit_card('4255555555555555')
    @invalid_cvc   = credit_card('4024007148673576', {:verification_value => ''})
    @options = {
      :description => 'Active Merchant',
      :email => 'active.merchant@testing.test'
    }
  end

  def test_missing_secret_key
    assert_raise ArgumentError do
      OmiseGateway.new()
    end
  end

  def test_successful_purchase
    response = @gateway.purchase(@amount, @credit_card)
    assert_success response
    assert_equal 'Success', response.message
    assert_equal response.params['amount'], @amount
    assert response.params['captured'], 'captured should be true'
    assert response.params['authorized'], 'authorized should be true'
  end

  def test_failed_purchase
    response = @gateway.purchase(@amount, @invalid_cvc)
    assert_failure response
    assert_equal Gateway::STANDARD_ERROR_CODE[:invalid_cvc], response.error_code
  end

  def test_successful_purchase_with_token
    token = @gateway.send(:omise_tokenize, @credit_card)
    assert token.is_a?(OmisePaymentToken)
    token_id = token.payment_data.params['token']['id']
    response = @gateway.purchase(@amount, nil, {:token_id=>token_id})
    assert_success response
    assert_equal response.params['amount'], @amount
  end

  def test_failed_purchase_with_token
    response = @gateway.purchase(@amount, nil, {:token_id=>'tokn_invalid_12345'})
    assert_failure response
  end

  def test_successful_store
    response = @gateway.store(@credit_card, @options)
    assert_success response
    assert response.params['id'].match(/cust_test_[1-9a-z]+/)
  end

  def test_successful_unstore
    response = @gateway.store(@credit_card, @options)
    customer = @gateway.unstore(response.params['id'])
    assert_equal true, customer.params['deleted']
  end

  def test_successful_store_with_token
    token = @gateway.send(:omise_tokenize, @credit_card)
    assert token.is_a?(OmisePaymentToken)
    @options[:token_id] = token.payment_data.params['token']['id']
    response = @gateway.store(nil, @options)
    assert_success response
    customer = @gateway.unstore(response.params['id'])
    assert_equal true, customer.params['deleted']
  end

  def test_authorize
    authorize = @gateway.authorize(@amount, @credit_card, @options)
    assert_success authorize
    assert_equal authorize.params['amount'], @amount
    assert !authorize.params['captured'], 'captured should be false'
    assert authorize.params['authorized'], 'authorized should be true'
  end

  def test_authorize_and_capture
    authorize = @gateway.authorize(@amount, @credit_card, @options)
    capture   = @gateway.capture(@amount, authorize.authorization, @options)
    assert_success capture
    assert capture.params['captured'], 'captured should be true'
    assert capture.params['authorized'], 'authorized should be true'
  end

  def test_successful_store_with_customer
    response = @gateway.store(@credit_card, @options)
    assert_success response
    customer_id  = response.params['id']
    default_card = response.params['default_card']
    resp = @gateway.store(credit_card('4111111111111111'), {customer_id: customer_id, set_default_card: true})
    new_default_card = resp.params['default_card']
    assert new_default_card.match(/card_test_[1-9a-z]+/)
    assert default_card != new_default_card
  end

  def test_failed_store
    response = @gateway.store(@declined_card, @options)
    assert_failure response
  end

  def test_successful_void
    purchase = @gateway.purchase(@amount, @credit_card, @options)
    assert_success purchase
    assert_equal purchase.params['amount'], @amount
    response = @gateway.void(purchase.authorization)
    assert_success response
    assert_equal response.params['amount'], @amount
  end

  def test_successful_refund
    purchase = @gateway.purchase(@amount, @credit_card, @options)
    assert_success purchase
    assert_equal purchase.params['amount'], @amount
    response = @gateway.refund(@amount-1000, purchase.authorization)
    assert_success response
    assert_equal @amount-1000, response.params['amount']
  end

  def test_successful_verify
    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_match %r{Success}, response.message
  end

end
