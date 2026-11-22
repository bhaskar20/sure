# frozen_string_literal: true

# Reads who is on the other side of a bank statement line from its raw
# description, with no model and no database: the payment rail, the direction
# when the text states it, partial account and card numbers, payment handles,
# labelled names and explicit own-account markers.
#
# Only the last four digits of an account or card number ever leave the parser.
# Reference numbers are deliberately ignored: a number counts only when a label,
# a mask or a card-number shape says what it is.
class Transaction::CounterpartyParser
  Result = Data.define(
    :rail, :direction, :account_fragments, :own_card_fragments, :handles, :names,
    :self_marker, :wallet_topup, :known_wallet, :card_payment
  ) do
    def self.empty
      new(
        rail: nil, direction: nil, account_fragments: [], own_card_fragments: [], handles: [], names: [],
        self_marker: false, wallet_topup: nil, known_wallet: false, card_payment: false
      )
    end

    def empty?
      rail.nil? && direction.nil? && !signals?
    end

    # True when the line says something about who the counterparty is, beyond
    # the rail and direction.
    def signals?
      account_fragments.any? || own_card_fragments.any? || handles.any? || names.any? ||
        self_marker || wallet_topup.present? || card_payment
    end
  end

  # Inputs are bounded so every regex below runs on a short string.
  MAX_LENGTH = 1024

  # First match wins, so the more specific rail comes first (PAYNOW runs over
  # FAST, FASTER PAYMENTS is not FAST).
  RAILS = [
    [ :upi, /\bUPI\b/ ],
    [ :imps, /\bIMPS\b/ ],
    [ :neft, /\bNEFT\b/ ],
    [ :rtgs, /\bRTGS\b/ ],
    [ :paynow, /\bPAYNOW\b/ ],
    [ :faster_payments, /\bFASTER\s+PAYMENTS?\b|\bFPS\b/ ],
    # A bare FAST is an English word; it is a rail only next to a payment noun.
    [ :fast, %r{\bFAST(?:\s+(?:PAYMENT|COLLECTION|TRANSFER|RECEIPT|CREDIT|DEBIT)S?\b|[/-])} ],
    [ :giro, /\bGIRO\b/ ],
    [ :zelle, /\bZELLE\b/ ],
    [ :sepa, /\bSEPA\b/ ],
    [ :ach, /\bACH\b/ ],
    [ :wire, /\bWIRE\b|\bSWIFT\b/ ],
    [ :standing_order, %r{\bSTANDING\s+ORDER\b|\bS/O\b} ],
    [ :card, /\bDEBIT\s+CARD\b|\bCARD\s+(?:TRANSACTION|PURCHASE|TXN)\b|\bPOS\b|\bVISA\s+DEBIT\b/ ]
  ].freeze

  # Explicit markers outrank connector words: an incoming PayNow line can still
  # read "FUND TRANSFER TO +65...", naming the payee's own handle.
  STRONG_IN = %r{\bINCOMING\b|\bFROM:|/CR/|\bCR/}
  STRONG_OUT = %r{\bOUTGOING\b|\bTO:|/DR/|\bDR/}
  WEAK_IN = /\b(?:TRANSFER|RECEIVED|PAYMENT|CREDIT|ZELLE|DEPOSIT)\s+FROM\b/
  WEAK_OUT = /\b(?:TRANSFER|PAYMENT|ZELLE|SENT|TOP[\s-]?UP|PAID)\s+TO\b/

  # SELF and OWN ACCOUNT count only in a transfer: "SELF STORAGE", "HMRC SELF
  # ASSESSMENT" and "OWN ACCOUNT FEE" are purchases and charges. The compound
  # list matches word beginnings, since banks truncate ("SELF ASSESSMEN").
  SELF_COMPOUND = /[\s-](?:SERV|STOR|ASSES|ASSMT|DRIV|CHECK|CARE|PARK|HELP|EMPLOY|DEFEN|PORTRAIT|ESTEEM|CATER)/
  SELF_SEGMENT = %r{(?:[/-]SELF(?=[/-]|\s|\z)|\bTO\s+SELF\b|\bSELF\s+(?:TRANSFER|TRF|A/C)\b)(?!#{SELF_COMPOUND.source})}
  SELF_WORD = /\bSELF\b(?!#{SELF_COMPOUND.source})/
  TRANSFER_CONTEXT = %r{\b(?:TRANSFER|TRF|NEFT|IMPS|RTGS|UPI|A/C)\b}
  OWN_ACCOUNT = %r{\b(?:TRANSFER|TRF)\b.{0,40}\bOWN\s+(?:A/C|ACCOUNTS?|ACCT)\b|\bOWN\s+(?:A/C|ACCOUNTS?|ACCT)\s+(?:TRANSFER|TRF)\b|\bBETWEEN\s+OWN\s+ACCOUNTS\b|\bINTERNAL\s+TRANSFER\b}
  # A fee or charge for a transfer is not the transfer.
  TRANSFER_FEE = /\b(?:FEES?|CHARGES?|COMMISSION)\b/

  # 16-digit card numbers, grouped or not, and 15-digit Amex numbers. The word
  # boundaries keep longer reference numbers out.
  CARD_NUMBER = /\b\d{4}([\s-]?)\d{4}\1\d{4}\1\d{4}\b|\b\d{4}[\s-]?\d{6}[\s-]?\d{5}\b/
  CARD_LABELLED = /\bCARD\s*(?:NO\b\.?|NUMBER\b|ENDING(?:\s+IN)?\b)?\s*[:#-]?\s*(?:X+|\*+|•+)?\s*(\d{4})\b/
  CARD_PURCHASE_CONTEXT = /\bDEBIT\s+CARD\b|\bCARD\s+(?:TRANSACTION|PURCHASE|TXN)\b|\bPOS\b|\bPURCHASE\b/

  LABELLED_ACCOUNT = %r{(?:\bA/C|\bACCT\b|\bACCOUNT\b)\.?(?:\s*(?:NO|NUMBER|NUM)\b\.?)?\s*[:#-]?\s*(?:X+|\*+|•+)?\s*(\d[\d-]{2,24}\d)\b}
  MASKED_ACCOUNT = /(?:\bX{1,}|\*{2,}|•{2,}|\.{2,})\s?(\d{4,6})\b/
  ENDING_ACCOUNT = /\bENDING(?:\s+IN)?\s*[:#-]?\s*(?:X+|\*+|•+|\.+)?\s*(\d{4})\b/
  IBAN = /\bIBAN\s*[:#]?\s*([A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){2,7}(?:\s?[A-Z0-9]{1,3})?)\b/

  # Lowercase-insensitive because the text is upcased; the bank part has no dot,
  # which keeps ordinary email addresses out.
  VPA = /\b([A-Z0-9][A-Z0-9._-]{1,63}@[A-Z][A-Z0-9]{1,31})\b(?!\.[A-Z])/
  # A phone number is a handle only right after a payment-handle word.
  PHONE = /(?:\bPAYNOW|\bPAYLAH!?|\bMOBILE(?:\s+NO\b\.?)?|\bTOP[\s-]?UP(?:\s+TO)?(?:\s+PAYLAH!?)?)\s*[:-]?\s*(\+\d{1,3}[\s-]?)?(\d{4}[\s-]?\d{4}|\d{10})\b|\bTO\s*(\+\d{1,3}[\s-]?)(\d{4}[\s-]?\d{4}|\d{10})\b/
  UPI_MOBILE = /\bUPI\s*[:-]?\s*(?:\+?91[\s-]?)?([6-9]\d{9})\b/

  WALLETS = [
    "PAYLAH", "GRABPAY", "PAYTM", "PHONEPE", "AMAZON PAY", "MOBIKWIK", "FREECHARGE", "SHOPEEPAY", "GOPAY",
    "TOUCH N GO", "PAYPAL", "VENMO", "CASH APP", "ALIPAY", "WECHAT PAY", "REVOLUT", "YOUTRIP"
  ].freeze
  WALLET_CONTEXT = /\bTOP[\s-]?UP\b|\bWALLET\s+(?:LOAD|TOP[\s-]?UP|RELOAD)\b|\b(?:ADD|LOAD)\s+MONEY\b|\bRELOAD\b/
  NOT_WALLETS = %w[MOBILE PHONE PREPAID CARD ACCOUNT FROM].freeze
  WALLET_TARGET = /(?:\bTOP[\s-]?UP|\bWALLET\s+(?:LOAD|TOP[\s-]?UP|RELOAD)|\b(?:ADD|LOAD)\s+MONEY|\bRELOAD)(?:\s+(?:TO|OF|FOR|IN|INTO))?\s*[:-]?\s*([A-Z][A-Z0-9!'.& ]{2,30})/

  CARD_PAYMENT = Regexp.union(
    /\bCREDIT\s+CARD\s+(?:BILL\s+)?PAYMENT\b/,
    /\bCC\s+(?:BILL\s+)?PAYMENT\b/,
    /\bCARD\s+BILL\s+PAYMENT\b/,
    /\bBILL\s+PAYMENT\s*[:-]?\s*DBSC\b/,
    /\bAUTO\s?PAY\b.{0,40}\bCREDIT\s+(?:CARD|CRD)\b/,
    %r{\bPAYMENT\s*-\s*DBS\s+INTERNET/WIRELESS\b},
    /\bPAYMENT\s+RECEIVED\s*[-,]?\s*THANK\s+YOU\b/,
    /\bTHANK\s+YOU\s+FOR\s+YOUR\s+PAYMENT\b/,
    /\bBILLDESK\s?\*\s?CARD\b/
  )
  BILL_PAYMENT = /\bBILL\s+PAYMENT\b/

  NAME_LABEL = /(?:\bFROM:|\bTO:|\bBY:|\bBENEFICIARY(?:\s+NAME)?\s*:|\bBENE(?:\s+NAME)?\s*:|\bPAYEE\s*:|\b(?:TRANSFER|ZELLE|PAYMENT|RECEIVED|SENT)\s+(?:TO|FROM)\b)\s*/
  NAME_STOP_WORDS = %w[
    REF REF: REF. REFERENCE REF# NO NO. OTHER PAYNOW IBAN ON VIA A/C ACCT ACCOUNT SELF FOR AT
    FROM: TO: BY: ENDING XX # - / :
  ].freeze
  # Account types and wallets that follow "TRANSFER TO" but are not a name.
  GENERIC_NAME_WORDS = %w[
    SAV SAVINGS SAVING CHK CHECKING CHEQUING CURRENT CREDIT CARD LOAN WALLET DEPOSIT FIXED MY OWN THE
  ].freeze
  MAX_NAME_TOKENS = 8

  # Segments of a UPI/IMPS slash string that are not the counterparty's name.
  SLASH_FLAGS = %w[DR CR P2A P2M P2P IN OUT MMT].freeze

  def self.parse(text)
    new(text).parse
  end

  def initialize(text)
    @text = normalize(text)
  end

  def parse
    return Result.empty if @text.blank?

    card_payment = card_payment?
    account_fragments, own_card_fragments = fragments(card_payment)

    Result.new(
      rail: rail,
      direction: direction,
      account_fragments: account_fragments.freeze,
      own_card_fragments: own_card_fragments.freeze,
      handles: handles.freeze,
      names: names.freeze,
      self_marker: self_marker?,
      wallet_topup: wallet&.first,
      known_wallet: wallet&.last || false,
      card_payment: card_payment
    )
  end

  private
    def normalize(text)
      string = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      string[0, MAX_LENGTH].upcase.squish
    end

    def rail
      RAILS.each { |name, pattern| return name if pattern.match?(@text) }
      nil
    end

    def direction
      side = one_side(STRONG_IN.match?(@text), STRONG_OUT.match?(@text))
      side || one_side(WEAK_IN.match?(@text), WEAK_OUT.match?(@text))
    end

    def one_side(inbound, outbound)
      return :in if inbound && !outbound
      :out if outbound && !inbound
    end

    def card_payment?
      return true if CARD_PAYMENT.match?(@text)
      BILL_PAYMENT.match?(@text) && CARD_NUMBER.match?(@text)
    end

    # Card numbers are read first and cut out of the text, so the generic
    # account patterns never see them a second time.
    def fragments(card_payment)
      full_cards = []
      labelled_cards = []
      remaining = @text.gsub(CARD_NUMBER) do
        full_cards << last4(Regexp.last_match(0))
        " "
      end
      remaining = remaining.gsub(CARD_LABELLED) do
        labelled_cards << last4(Regexp.last_match(1))
        " "
      end

      accounts = []
      [ LABELLED_ACCOUNT, MASKED_ACCOUNT, ENDING_ACCOUNT ].each do |pattern|
        remaining.scan(pattern) { |(digits)| accounts << last4(digits) }
      end
      remaining.scan(IBAN) do |(iban)|
        tail = iban.delete(" ")[-4..]
        accounts << tail if tail&.match?(/\A\d{4}\z/)
      end

      # A card on a purchase is the statement's own; one being paid or
      # transferred to is the counterparty. A bare card-shaped number with
      # neither context is too likely to be a reference, so it is dropped.
      cards = []
      if card_payment
        accounts = full_cards + labelled_cards + accounts
      elsif CARD_PURCHASE_CONTEXT.match?(@text)
        cards = full_cards + labelled_cards
      else
        accounts = labelled_cards + accounts
      end

      cards = cards.compact.uniq
      [ (accounts.compact.uniq - cards), cards ]
    end

    def last4(value)
      digits = value.to_s.gsub(/\D/, "")
      digits.length >= 4 ? digits[-4..] : nil
    end

    def handles
      found = []
      @text.scan(VPA) { |(vpa)| found << vpa.downcase }
      @text.scan(PHONE) do |_country_a, number_a, _country_b, number_b|
        found << (number_a || number_b).gsub(/\D/, "")[-8..]
      end
      @text.scan(UPI_MOBILE) { |(number)| found << number[-8..] }
      found.uniq
    end

    def self_marker?
      return false if TRANSFER_FEE.match?(@text)

      SELF_SEGMENT.match?(@text) || (SELF_WORD.match?(@text) && TRANSFER_CONTEXT.match?(@text)) || OWN_ACCOUNT.match?(@text)
    end

    # [name, known] for the wallet a top-up goes to. A known wallet must be what
    # is topped up, not just mentioned ("PAYPAL *STEAM RELOAD" is a purchase);
    # any other word after the top-up ("TOP UP STARHUB") is returned as unknown,
    # for matching against the family's account names only.
    def wallet
      return @wallet if defined?(@wallet)

      @wallet = begin
        target = @text[WALLET_TARGET, 1] if WALLET_CONTEXT.match?(@text)
        if target
          known = (WALLETS + [ "WALLET" ]).find { |name| target.match?(/\A#{Regexp.escape(name)}\b/) }
          if known
            [ known.delete(" "), true ]
          else
            candidate = target[/\A[A-Z][A-Z!'.&]{2,20}/]&.gsub(/[^A-Z]/, "")
            [ candidate, false ] if candidate.present? && candidate.length >= 3 && NOT_WALLETS.exclude?(candidate)
          end
        end
      end
    end

    def names
      (labelled_names + slash_names).uniq
    end

    def labelled_names
      found = []
      @text.scan(NAME_LABEL) do
        rest = Regexp.last_match.post_match
        name = name_from_tokens(rest.split(" ").first(MAX_NAME_TOKENS + 2))
        found << name if name
      end
      found
    end

    def name_from_tokens(tokens)
      taken = []
      tokens.each_with_index do |token, index|
        break if name_stop?(token, tokens[index + 1])
        taken << token
        break if taken.length >= MAX_NAME_TOKENS
      end
      clean_name(taken)
    end

    def name_stop?(token, following)
      return true if NAME_STOP_WORDS.include?(token)
      return true if token.match?(/\d/) || token.start_with?("+", "@") || token.include?("@")
      return true if token.match?(/\A[A-Z]+:\z/)
      return true if token == "FUND" && following == "TRANSFER"
      token == "PAYNOW"
    end

    def clean_name(tokens)
      return if tokens.empty?
      return if tokens.all? { |token| GENERIC_NAME_WORDS.include?(token.gsub(/[^A-Z]/, "")) }

      name = tokens.join(" ").sub(/[^A-Z0-9]+\z/, "").squish
      name if name.match?(/[A-Z]{2}/)
    end

    def slash_names
      return [] unless @text.match?(%r{\b(?:UPI|IMPS)/})

      segments = @text.split("/").map(&:strip)
      start = segments.index { |segment| segment.match?(/\A(?:UPI|IMPS)\z/) || segment.end_with?(" UPI", " IMPS") }
      return [] unless start

      segments[(start + 1)..].each do |segment|
        next if SLASH_FLAGS.include?(segment) || segment.match?(/\A\d+\z/)
        return [] unless segment.match?(/\A[A-Z][A-Z .&']*\z/) && segment.match?(/[A-Z]{2}|[A-Z]+ [A-Z]/)
        name = clean_name(segment.split(" "))
        return name ? [ name ] : []
      end
      []
    end
end
