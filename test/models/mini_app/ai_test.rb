require "test_helper"

class MiniApp::AiTest < ActiveSupport::TestCase
  ChatMessage = Provider::LlmConcept::ChatMessage
  ChatResponse = Provider::LlmConcept::ChatResponse

  setup do
    @app = mini_apps(:recategorizer)
    @admin = users(:family_admin)
    @app.update!(manifest: @app.manifest.merge("permissions" => @app.manifest["permissions"] + [ "ai:use" ]))
    @app.update_grants!(permissions: @app.granted_permissions + [ "ai:use" ])
    Rails.cache.clear
  end

  test "completes a prompt with Sure's provider and reports where it ran" do
    provider = local_provider
    provider.expects(:chat_response)
            .with("Explain my plan", model: "sure-local", instructions: "Be brief.", family: @app.family)
            .returns(success("Save $500 a month."))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    result = ai_complete("prompt" => "Explain my plan", "instructions" => "Be brief.")[:result]

    assert_equal({ text: "Save $500 a month.", model: "sure-local", local: true }, result)
  end

  test "is refused without ai:use and logged as denied" do
    @app.update_grants!(permissions: @app.granted_permissions - [ "ai:use" ])
    Provider::Registry.expects(:preferred_llm_provider).never

    error = ai_complete("prompt" => "hi")[:error]

    assert_equal(-32003, error[:code])
    assert_equal "ai:use", error[:data][:permission]
    assert_equal "denied", @app.activities.order(:created_at).last.outcome
  end

  test "logs size, model and locality but never the prompt or reply" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(local_provider.tap { |p| p.stubs(:chat_response).returns(success("secret reply")) })

    ai_complete("prompt" => "my salary is 123456")
    activity = @app.activities.order(:created_at).last

    assert_equal [ "sure/ai/complete", "ok", "ai:use" ], [ activity.rpc_method, activity.outcome, activity.permission ]
    assert_equal 19, activity.summary["promptLength"]
    assert_equal true, activity.summary["local"]
    assert_no_match(/123456|secret reply/, activity.summary.to_json)
  end

  test "says AI is unavailable when Sure has no model set up" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    assert_equal(-32007, ai_complete("prompt" => "hi")[:error][:code])
  end

  test "hides provider failures behind a generic error" do
    provider = local_provider
    provider.stubs(:chat_response).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("upstream 500 with key sk-123")))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    error = ai_complete("prompt" => "hi")[:error]

    assert_equal(-32008, error[:code])
    assert_no_match(/sk-123/, error[:message])
  end

  test "rejects empty, oversized and malformed prompts before calling the model" do
    Provider::Registry.expects(:preferred_llm_provider).never

    [ { "prompt" => "  " }, { "prompt" => "x" * 20_001 }, { "prompt" => 42 },
      { "prompt" => "hi", "instructions" => "x" * 4_001 } ].each do |params|
      assert_equal(-32602, ai_complete(params)[:error][:code], params.inspect)
    end
  end

  test "has its own tighter rate limit" do
    Rails.cache.stubs(:increment).returns(MiniApp::Bridge::AI_RATE_LIMIT + 1)
    Provider::Registry.expects(:preferred_llm_provider).never

    assert_equal(-32029, ai_complete("prompt" => "hi")[:error][:code])
  end

  test "ui/initialize advertises AI only to apps holding ai:use" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(local_provider)

    assert_equal({ available: true, local: true, model: "sure-local" }, initialize_result[:capabilities][:ai])

    @app.update_grants!(permissions: @app.granted_permissions - [ "ai:use" ])
    assert_nil initialize_result[:capabilities][:ai]
  end

  test "a loopback OpenAI-compatible endpoint is local; hosted and remote ones are not" do
    assert Provider::Openai.new("key", uri_base: "http://127.0.0.1:8080/v1", model: "m").local_endpoint?
    assert Provider::Openai.new("key", uri_base: "http://localhost:8080/v1", model: "m").local_endpoint?
    assert Provider::Openai.new("key", uri_base: "http://[::1]:8080/v1", model: "m").local_endpoint?
    assert_not Provider::Openai.new("key", uri_base: "https://llm.example.com/v1", model: "m").local_endpoint?
    assert_not Provider::Openai.new("key").local_endpoint?
  end

  private
    def ai_complete(params)
      MiniApp::Bridge.new(mini_app: @app.reload, user: @admin)
                     .handle({ "jsonrpc" => "2.0", "id" => 1, "method" => "sure/ai/complete", "params" => params })
    end

    def initialize_result
      MiniApp::Bridge.new(mini_app: @app.reload, user: @admin)
                     .handle({ "jsonrpc" => "2.0", "id" => 1, "method" => "ui/initialize" })[:result]
    end

    def local_provider
      provider = Provider::Openai.new("key", uri_base: "http://127.0.0.1:8080/v1", model: "sure-local")
      provider.class.stubs(:effective_model).returns("sure-local")
      provider
    end

    def success(text)
      Provider::Response.new(success?: true, error: nil,
                             data: ChatResponse.new(id: "r1", model: "sure-local", messages: [ ChatMessage.new(id: "m1", output_text: text) ], function_requests: []))
    end
end
