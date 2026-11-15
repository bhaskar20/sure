module Assistant::TokenEstimator
  CHARS_PER_TOKEN = 4
  SAFETY_FACTOR = 1.25

  def self.estimate(value)
    chars = char_length(value)
    ((chars / CHARS_PER_TOKEN.to_f) * SAFETY_FACTOR).ceil
  end

  # For number-heavy data such as tool results: local tokenizers (Qwen, Llama)
  # spend about one token per digit, so a balance series costs several times
  # what the character-based estimate above predicts.
  def self.estimate_data(value)
    text = value.is_a?(String) ? value : value.to_json
    digits = text.count("0-9")
    (((text.length - digits) / CHARS_PER_TOKEN.to_f + digits) * SAFETY_FACTOR).ceil
  end

  def self.char_length(value)
    case value
    when nil    then 0
    when String then value.length
    when Array  then value.sum { |v| char_length(v) }
    when Hash   then value.to_json.length
    else value.to_s.length
    end
  end
end
