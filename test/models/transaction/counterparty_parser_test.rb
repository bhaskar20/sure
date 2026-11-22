require "test_helper"

class Transaction::CounterpartyParserTest < ActiveSupport::TestCase
  def parse(text)
    Transaction::CounterpartyParser.parse(text)
  end

  test "nil and blank input return an empty result" do
    [ nil, "", "   ", "\n" ].each do |text|
      result = parse(text)
      assert result.empty?, "expected #{text.inspect} to be empty"
      assert_equal [], result.account_fragments
      assert_equal false, result.self_marker
    end
  end

  test "a line with no counterparty is empty" do
    assert parse("Interest Earned").empty?
    assert parse("SERVICE CHARGE 12.50").empty?
  end

  # Singapore

  test "incoming PayNow reads the payer name and the phone handle" do
    result = parse("Advice FAST Payment / Receipt INCOMING PAYNOW REF 0899999 FROM: TAN WEI MING FUND TRANSFER TO +6598765432")

    assert_equal :paynow, result.rail
    assert_equal :in, result.direction
    assert_equal [ "TAN WEI MING" ], result.names
    assert_equal [ "98765432" ], result.handles
    assert_equal [], result.account_fragments
  end

  test "outgoing PayNow reads the payee business name" do
    result = parse("Advice FAST Payment / Receipt PAYNOW TRANSFER 8002222 TO: ACME MART PTE. LTD.")

    assert_equal :paynow, result.rail
    assert_equal :out, result.direction
    assert_equal [ "ACME MART PTE. LTD" ], result.names
    assert_equal [], result.handles
  end

  test "wallet top-up reads the wallet and phone handle" do
    result = parse("Advice Funds Transfer TOP-UP TO PAYLAH! : 98765432")

    assert_equal "PAYLAH", result.wallet_topup
    assert_equal [ "98765432" ], result.handles
    assert_equal :out, result.direction
    assert_equal [], result.names
  end

  test "card bill payment reads the card fragment and ignores the long reference" do
    result = parse("Advice Bill Payment DBSC-5500000000003333 : I-BANK REF: 10000000000000000042")

    assert result.card_payment
    assert_equal [ "3333" ], result.account_fragments
    assert_equal [], result.own_card_fragments
  end

  test "debit card purchase reads the statement's own card, not a counterparty" do
    result = parse("Debit Card Transaction SP DIGITAL PL-UTIL-RE SI SGP 07OCT 4000-1234-5678-9010")

    assert_equal :card, result.rail
    assert_equal [ "9010" ], result.own_card_fragments
    assert_equal [], result.account_fragments
    refute result.card_payment
  end

  test "FAST collection with alphanumeric references has no fragments" do
    result = parse("Advice FAST Collection DS1000001 ABCDEF123456789XYZ12345 OTHER")

    assert_equal :fast, result.rail
    assert_equal [], result.account_fragments
    assert_equal [], result.own_card_fragments
    assert_equal [], result.handles
    assert_equal [], result.names
  end

  # India

  test "transfer to a labelled own account" do
    result = parse("ONLINE FUND TRANSFER TO A/C NO 30000000123 SELF")

    assert result.self_marker
    assert_equal [ "0123" ], result.account_fragments
    assert_equal :out, result.direction
    assert_equal [], result.names
  end

  test "NEFT reference numbers are not account numbers" do
    result = parse("NEFT ABCDN12000000000000001 GLOBEX HONG KONG FOR INITECH INC ABC BANK IN5IN000000000AB BATCHID:0001P0001")

    assert_equal :neft, result.rail
    assert_equal [], result.account_fragments
    assert_equal [], result.handles
    assert_nil result.direction
  end

  test "UPI debit reads the VPA and the name segment" do
    result = parse("UPI/DR/400000000001/ASHA M/okaxis/asha.m@okaxis/Payment")

    assert_equal :upi, result.rail
    assert_equal :out, result.direction
    assert_equal [ "asha.m@okaxis" ], result.handles
    assert_equal [ "ASHA M" ], result.names
  end

  test "UPI credit direction" do
    assert_equal :in, parse("UPI/CR/400000000002/VIKRAM S/ybl/vikram@ybl").direction
  end

  test "IMPS masked account" do
    result = parse("IMPS/P2A/600000000001/XXXX5150/Savings")

    assert_equal :imps, result.rail
    assert_equal [ "5150" ], result.account_fragments
    assert_equal [], result.names
  end

  test "NEFT self transfer with masked account" do
    result = parse("NEFT-SELF-HDFC0000001-XXXXXXXX7788")

    assert_equal :neft, result.rail
    assert result.self_marker
    assert_equal [ "7788" ], result.account_fragments
  end

  # Western

  test "transfer to savings with a dotted mask" do
    result = parse("Online Transfer to SAV ...6060 Ref #IB0001")

    assert_equal [ "6060" ], result.account_fragments
    assert_equal :out, result.direction
    assert_equal [], result.names
  end

  test "ending in a number" do
    assert_equal [ "6060" ], parse("Transfer to Savings ending 6060").account_fragments
    assert_equal [ "6060" ], parse("TRANSFER TO CHECKING ENDING IN 6060").account_fragments
  end

  test "Zelle reads the payee name and stops at the date" do
    result = parse("ZELLE TO ALEX ROE ON 03/02 REF # PP0TEST01")

    assert_equal :zelle, result.rail
    assert_equal :out, result.direction
    assert_equal [ "ALEX ROE" ], result.names
    assert_equal [], result.account_fragments
  end

  test "SEPA credit reads the payer name and IBAN fragment" do
    result = parse("SEPA CREDIT TRANSFER FROM SAM DOE IBAN DE00123456781234567890")

    assert_equal :sepa, result.rail
    assert_equal :in, result.direction
    assert_equal [ "SAM DOE" ], result.names
    assert_equal [ "7890" ], result.account_fragments
  end

  test "credit card payment phrasings" do
    [
      "CREDIT CARD PAYMENT THANK YOU",
      "AUTOPAY BIGBANK CREDIT CRD",
      "CC PAYMENT",
      "PAYMENT RECEIVED THANK YOU",
      "PAYMENT - DBS INTERNET/WIRELESS"
    ].each do |text|
      assert parse(text).card_payment, "expected #{text.inspect} to be a card payment"
    end
  end

  test "credit card payment with a full card number keeps only the last four" do
    result = parse("CREDIT CARD PAYMENT 4111-1111-1111-4321")

    assert result.card_payment
    assert_equal [ "4321" ], result.account_fragments
    assert_equal [], result.own_card_fragments
  end

  test "card purchase with a labelled card number" do
    result = parse("POS PURCHASE COFFEE HOUSE CARD 4455")

    assert_equal :card, result.rail
    assert_equal [ "4455" ], result.own_card_fragments
    assert_equal [], result.account_fragments
  end

  test "a card being transferred to is a counterparty, not the own card" do
    result = parse("TRANSFER TO CARD XXXX1234")

    assert_equal [ "1234" ], result.account_fragments
    assert_equal [], result.own_card_fragments
  end

  test "labelled account numbers strip separators" do
    assert_equal [ "7890" ], parse("TRANSFER ACCOUNT NO. 123-456789-0").account_fragments
    assert_equal [ "1234" ], parse("PAYMENT ACCT XX1234").account_fragments
    assert_equal [ "1234" ], parse("ACH A/C 1234").account_fragments
  end

  test "masked number shapes" do
    assert_equal [ "1234" ], parse("TRF ****1234").account_fragments
    assert_equal [ "1234" ], parse("TRF •••• 1234").account_fragments
    assert_equal [ "1234" ], parse("transfer to x1234").account_fragments
  end

  test "fragments are deduplicated in order" do
    assert_equal [ "1111", "2222" ], parse("A/C 0001111 XXXX1111 XX2222").account_fragments
  end

  test "rails anywhere in the text" do
    {
      "PAYMENT VIA RTGS 123" => :rtgs,
      "GIRO - ELECTRICITY" => :giro,
      "ACH DEBIT UTILITY CO" => :ach,
      "FASTER PAYMENT RECEIVED" => :faster_payments,
      "INTERNATIONAL WIRE OUT" => :wire,
      "STANDING ORDER RENT" => :standing_order
    }.each do |text, rail|
      assert_equal rail, parse(text).rail, text
    end
  end

  test "FAST as an ordinary word is not a rail" do
    assert_nil parse("FAST FOOD CORNER").rail
    assert_nil parse("BREAKFAST CLUB").rail
  end

  # Self markers

  test "self markers" do
    [ "TO SELF", "SELF TRANSFER", "OWN A/C TRF", "TRANSFER BETWEEN OWN ACCOUNTS", "INTERNAL TRANSFER" ].each do |text|
      assert parse(text).self_marker, "expected #{text.inspect} to be a self marker"
    end
  end

  test "words containing SELF are not self markers" do
    refute parse("SELFRIDGES LONDON").self_marker
    refute parse("PAYMENT TO MYSELF STORE").self_marker
    refute parse("SELF SERVICE KIOSK").self_marker
  end

  # Wallets

  test "wallet top-up names" do
    assert_equal "GRABPAY", parse("TOPUP GRABPAY").wallet_topup
    assert_equal "PAYTM", parse("WALLET LOAD PAYTM").wallet_topup
    assert_equal "WALLET", parse("ADD MONEY TO WALLET").wallet_topup
    assert_nil parse("GRABPAY SINGAPORE").wallet_topup
  end

  # Negatives

  test "phone-like numbers without a handle context are not handles" do
    assert_equal [], parse("PAYNOW REF 98765432").handles
    assert_equal [], parse("PAYMENT 98765432 RECEIVED").handles
    assert_equal [], parse("UPI/DR/412345678901/X/y").handles
  end

  test "bare long numbers, dates and amounts are not fragments" do
    result = parse("TRANSFER 1234567890123456 07OCT 1,234.56 REF 00012345")

    assert_equal [], result.account_fragments
    assert_equal [], result.own_card_fragments
    assert_equal [], result.handles
  end

  test "email addresses are not VPAs" do
    assert_equal [], parse("PAYPAL someone@example.com").handles
  end

  test "names stop at a label and drop digit tokens" do
    assert_equal [ "JO BLOGGS" ], parse("BY: JO BLOGGS REF 123").names
    assert_equal [ "JO BLOGGS" ], parse("BENEFICIARY: JO BLOGGS 00012345").names
  end

  test "arbitrary and long garbage input is handled quickly" do
    inputs = [
      "X" * 5000,
      "1" * 5000,
      "A/C " + ("1-" * 3000),
      ("a." * 2000) + "@",
      "TO: " + ("AB " * 2000),
      (("UPI/" + "Z" * 10) * 300),
      "\xFF\xFE broken bytes A/C 1234".dup.force_encoding("BINARY")
    ]

    elapsed = Benchmark.realtime do
      inputs.each { |text| assert_kind_of Transaction::CounterpartyParser::Result, parse(text) }
    end
    assert elapsed < 1, "parsing took #{elapsed}s"
  end
  test "SELF and OWN ACCOUNT count only in a transfer" do
    [ "HMRC SELF ASSESSMENT", "PUBLIC STORAGE SELF STORAGE 0423", "ZOOMCAR SELF DRIVE BANGALORE",
      "SHELL SELF SERV 1234", "TESCO SELF CHECKOUT", "OWN ACCOUNT FEE", "SELF HELP BOOKS",
      "POS/SELF STORAGE SG", "VISA-SELF DRIVE CARS", "FAST PAYMENT TO SELF-STORAGE PTE", "TRF TO HMRC SELF ASSESSMEN",
      "OWN ACCOUNT TRANSFER FEE", "INTERNAL TRANSFER FEE" ].each do |text|
      refute parse(text).self_marker, text
    end

    [ "ONLINE FUND TRANSFER TO A/C NO 22111234567 SELF", "NEFT-SELF-HDFC0001234-XXXXXXXX9876",
      "IMPS/SELF/612345678901", "TRANSFER TO SELF", "FUNDS TRANSFER TO OWN ACCOUNT", "TRANSFER BETWEEN OWN ACCOUNTS" ].each do |text|
      assert parse(text).self_marker, text
    end
  end

  test "only a known wallet that is itself topped up is a known wallet" do
    paylah = parse("Advice Funds Transfer TOP-UP TO PAYLAH! : 91234567")
    assert_equal [ "PAYLAH", true ], [ paylah.wallet_topup, paylah.known_wallet ]

    starhub = parse("SINGTEL PREPAID TOP UP STARHUB")
    assert_equal [ "STARHUB", false ], [ starhub.wallet_topup, starhub.known_wallet ]

    steam = parse("PAYPAL *STEAM RELOAD")
    refute steam.known_wallet

    assert parse("ADD MONEY TO WALLET").known_wallet
  end
end
