# One Messages call whose answer comes back through a single tool, for
# callers that own their prompt and validate the answer themselves
# (PdfImport::Enricher). The schema is the caller's JSON Schema object.
class Provider::Anthropic::StructuredJsonRequest
  include Provider::Anthropic::Concerns::UsageRecorder
  include Provider::Anthropic::Concerns::StructuredOutput

  TOOL_NAME = "report_result".freeze
  # Enough for a batch of cleaned names; the statement details are far shorter.
  MAX_TOKENS = 4096

  attr_reader :client, :model, :instructions, :input, :schema, :operation, :langfuse_trace, :family

  def initialize(client, model:, instructions:, input:, schema:, operation:, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @instructions = instructions
    @input = input
    @schema = schema
    @operation = operation
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def call
    span = langfuse_trace&.generation(name: "#{operation}_api_call", model: model, input: { model: model })

    response = create_structured_message(
      tool_name: TOOL_NAME,
      operation: operation,
      model: model,
      max_tokens: MAX_TOKENS,
      system_: Provider::Anthropic.structured_output_system(instructions, model, TOOL_NAME),
      messages: [ { role: "user", content: input } ],
      tools: [ { name: TOOL_NAME, description: "Report the result.", input_schema: schema } ],
      tool_choice: Provider::Anthropic.structured_output_tool_choice(model, TOOL_NAME)
    )

    result = extract_input(response)
    record_usage(model, response.usage, operation: operation)
    span&.end(output: result, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: operation, error: e)
    raise
  end

  private
    def extract_input(response)
      tool_use = Array(response.content).find { |block| structured_block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME} (stop_reason: #{response.stop_reason})" unless tool_use

      input = structured_block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      input.is_a?(Hash) ? input.deep_stringify_keys : {}
    end
end
