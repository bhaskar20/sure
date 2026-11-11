# Runs a prompt through the AI provider Sure itself is set up with, for a mini
# app holding `ai:use`. In Sure Desktop with Local AI on, that provider is the
# bundled llama-server on this computer, so prompts never leave the machine.
#
# The model gets no tools: it cannot read or change the family's data. It only
# sees what the app puts in the prompt, and the app can only put there what
# its other grants let it read.
class MiniApp::Ai
  MAX_PROMPT_LENGTH = 20_000
  MAX_INSTRUCTIONS_LENGTH = 4_000

  Result = Data.define(:text, :model, :local)

  class Unavailable < StandardError; end
  class Failed < StandardError; end

  class << self
    # Where prompts would go, for the consent page and ui/initialize.
    def status
      provider = self.provider
      return { available: false, local: false, provider: nil, model: nil } unless provider

      { available: true, local: local?(provider), provider: provider.provider_name, model: provider.class.effective_model }
    end

    def provider
      Provider::Registry.preferred_llm_provider
    rescue Provider::Error, Provider::Registry::Error
      nil
    end

    def local?(provider)
      provider.respond_to?(:local_endpoint?) && provider.local_endpoint?
    end
  end

  def initialize(family:)
    @family = family
  end

  def complete(prompt:, instructions: nil)
    provider = self.class.provider
    raise Unavailable unless provider

    model = provider.class.effective_model
    response = provider.chat_response(prompt, model: model, instructions: instructions.presence, family: family)
    raise Failed, response.error&.message unless response.success?

    text = Array(response.data&.messages).map(&:output_text).compact.join("\n").strip
    Result.new(text: text, model: model, local: self.class.local?(provider))
  end

  private
    attr_reader :family
end
