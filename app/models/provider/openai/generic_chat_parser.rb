class Provider::Openai::GenericChatParser
  Error = Class.new(StandardError)

  def initialize(object)
    @object = object
  end

  def parsed
    ChatResponse.new(
      id: response_id,
      model: response_model,
      messages: messages,
      function_requests: function_requests
    )
  end

  private
    attr_reader :object

    ChatResponse = Provider::LlmConcept::ChatResponse
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatFunctionRequest = Provider::LlmConcept::ChatFunctionRequest

    def response_id
      object.dig("id")
    end

    def response_model
      object.dig("model")
    end

    def message_choice
      object.dig("choices", 0, "message")
    end

    # Tool-call markup a local model wrote as text instead of a structured
    # call (an unclosed block runs to the end of the reply).
    TOOL_CALL_MARKUP = %r{<tool_call>.*?(?:</tool_call>|\z)}m

    def messages
      content = message_choice&.dig("content").to_s.gsub(TOOL_CALL_MARKUP, "").strip
      return [] if content.blank?

      [
        ChatMessage.new(
          id: response_id,
          output_text: content
        )
      ]
    end

    def function_requests
      tool_calls = message_choice&.dig("tool_calls") || []

      tool_calls.map do |tool_call|
        ChatFunctionRequest.new(
          id: tool_call.dig("id"),
          call_id: tool_call.dig("id"),
          function_name: tool_call.dig("function", "name"),
          function_args: tool_call.dig("function", "arguments"),
          extra_content: tool_call.dig("extra_content")
        )
      end
    end
end
