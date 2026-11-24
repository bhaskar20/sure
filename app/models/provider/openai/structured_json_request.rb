# One chat-completions call that answers with a JSON object, for callers that
# own their prompt and validate the answer themselves (PdfImport::Enricher).
# Asks for json_object output and retries without it for hosts that reject the
# format, as local OpenAI-compatible servers often do.
class Provider::Openai::StructuredJsonRequest
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :instructions, :input, :operation, :langfuse_trace, :family, :custom_provider

  def initialize(client, model:, instructions:, input:, operation:, langfuse_trace: nil, family: nil, custom_provider: false)
    @client = client
    @model = model
    @instructions = instructions
    @input = input
    @operation = operation
    @langfuse_trace = langfuse_trace
    @family = family
    @custom_provider = custom_provider
  end

  def call
    call_with_format({ type: "json_object" })
  rescue Faraday::BadRequestError => e
    Rails.logger.warn("json_object mode failed for #{operation}, retrying without: #{e.message}")
    call_with_format(nil)
  end

  private
    def call_with_format(response_format)
      span = langfuse_trace&.generation(name: "#{operation}_api_call", model: model, input: { model: model })

      params = {
        model: model,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: input }
        ]
      }
      params[:response_format] = response_format if response_format

      response = client.chat(parameters: params)
      parsed = parse_json_flexibly(response.dig("choices", 0, "message", "content"))
      raise Provider::Openai::Error, "Expected a JSON object from #{operation}" unless parsed.is_a?(Hash)

      record_usage(model, response.dig("usage"), operation: operation)
      span&.end(output: parsed, usage: response.dig("usage"))
      parsed
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    # LLM output may wrap the JSON in markdown fences or thinking tags.
    def parse_json_flexibly(raw)
      raise Provider::Openai::Error, "No message content in response" if raw.blank?

      cleaned = raw.include?("</think>") ? raw.split("</think>", 2).last : raw
      JSON.parse(cleaned)
    rescue JSON::ParserError
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m || cleaned =~ /(\{[\s\S]*\})/m
        JSON.parse(Regexp.last_match(1))
      else
        raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
      end
    end
end
