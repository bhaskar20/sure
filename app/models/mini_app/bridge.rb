# Answers the JSON-RPC 2.0 messages a mini app's frame sends through the host
# page. Tools are the assistant's own Assistant::Function classes, so a mini
# app gets the same validation and tenancy as the assistant and /mcp; every
# call is checked against the app's grants for this user, on the server, each
# time. Storage methods only ever touch this app's own records.
class MiniApp::Bridge
  PROTOCOL_VERSION = "2026-11-11"
  BRIDGE_VERSION = 1

  RATE_LIMIT = 120
  RATE_LIMIT_WINDOW = 1.minute
  # Model calls are slow and, on a cloud provider, paid, so they get a far
  # tighter budget than data tools.
  AI_RATE_LIMIT = 20
  AI_PERMISSION = "ai:use"

  STORAGE_DEFAULT_LIMIT = 50
  STORAGE_MAX_LIMIT = 200
  MAX_LOGGED_ARGUMENTS_BYTES = 4.kilobytes
  MAX_TOOL_NAME_LENGTH = 100

  module Codes
    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    PERMISSION_DENIED = -32003
    APP_DISABLED = -32004
    CONFIRMATION_REQUIRED = -32005
    DECLINED = -32006
    AI_UNAVAILABLE = -32007
    AI_FAILED = -32008
    RATE_LIMITED = -32029
  end

  # Raised inside a handler to end the request with a JSON-RPC error.
  class Failure < StandardError
    attr_reader :code, :data

    def initialize(code, message, data = nil)
      @code = code
      @data = data
      super(message)
    end
  end

  attr_reader :mini_app, :user

  def initialize(mini_app:, user:)
    @mini_app = mini_app
    @user = user
  end

  def handle(message, confirmed: false, declined: false)
    request = normalize(message)
    return error_response(nil, Codes::PARSE_ERROR, t("errors.parse_error")) if request == :parse_error

    id = request.is_a?(Hash) ? request["id"] : nil
    unless valid_request?(request)
      return error_response(id, Codes::INVALID_REQUEST, t("errors.invalid_request"))
    end

    rpc_method = request["method"]
    params = request["params"]
    params = {} if params.nil?
    raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_params")) unless params.is_a?(Hash)

    ensure_member!
    ensure_enabled!(rpc_method, params)

    success_response(id, dispatch(rpc_method, params, confirmed: confirmed, declined: declined))
  rescue Failure => e
    error_response(id, e.code, e.message, e.data)
  end

  private
    def dispatch(rpc_method, params, confirmed:, declined:)
      case rpc_method
      when "ui/initialize" then initialize_result
      when "ping" then {}
      when "tools/list" then { tools: tools_list }
      when "tools/call" then call_tool(params, confirmed: confirmed, declined: declined)
      when "sure/storage/get" then storage_get(params)
      when "sure/storage/set" then storage_set(params)
      when "sure/storage/delete" then storage_delete(params)
      when "sure/storage/list" then storage_list(params)
      when "sure/ai/complete" then ai_complete(params)
      else
        raise Failure.new(Codes::METHOD_NOT_FOUND, t("errors.method_not_found"))
      end
    end

    # --- validation --------------------------------------------------------

    def normalize(message)
      message = message.to_unsafe_h if message.respond_to?(:to_unsafe_h)
      message = JSON.parse(message) if message.is_a?(String)
      message.is_a?(Hash) ? message.deep_stringify_keys : message
    rescue JSON::ParserError
      :parse_error
    end

    def valid_request?(request)
      request.is_a?(Hash) &&
        request["jsonrpc"] == "2.0" &&
        request["method"].is_a?(String) && request["method"].present? &&
        (request["id"].nil? || request["id"].is_a?(String) || request["id"].is_a?(Integer))
    end

    def ensure_member!
      return if user.present? && mini_app.present? && user.family_id == mini_app.family_id

      raise Failure.new(Codes::PERMISSION_DENIED, t("errors.not_a_member"))
    end

    def ensure_enabled!(rpc_method, params)
      return if mini_app.enabled?

      if rpc_method == "tools/call"
        log_activity(outcome: :denied, tool: requested_tool_name(params), error_message: "app_disabled")
      end
      raise Failure.new(Codes::APP_DISABLED, t("errors.app_disabled"))
    end

    # --- ui/initialize -----------------------------------------------------

    def initialize_result
      family = mini_app.family

      {
        protocolVersion: PROTOCOL_VERSION,
        bridgeVersion: BRIDGE_VERSION,
        hostInfo: { name: "Sure" },
        app: { id: mini_app.app_key, name: mini_app.name, version: mini_app.version },
        permissions: effective_permissions,
        writePolicy: mini_app.write_policy,
        user: { name: user.display_name, role: user.role },
        family: { currency: family.currency, locale: family.locale, dateFormat: family.date_format },
        capabilities: { tools: {}, storage: {}, events: {}, ai: ai_capability }.compact
      }
    end

    # --- tools -------------------------------------------------------------

    def effective_permissions
      @effective_permissions ||= mini_app.effective_permissions_for(user)
    end

    # Catalog tools the assistant registry offers this user, keyed by name.
    def available_tool_classes
      @available_tool_classes ||= MiniApp::Permission.tool_classes_for(user).index_by(&:name)
    end

    def tools_list
      available_tool_classes.values.filter_map do |klass|
        permission = MiniApp::Permission.for_tool(klass.name)
        next unless effective_permissions.include?(permission)

        tool = klass.new(user)
        {
          name: tool.name,
          description: tool.description,
          inputSchema: tool.params_schema,
          permission: permission,
          write: MiniApp::Permission.write?(permission)
        }
      end
    end

    def call_tool(params, confirmed:, declined:)
      name = requested_tool_name(params)
      arguments = params["arguments"]
      arguments = {} if arguments.nil?

      unless name.present? && arguments.is_a?(Hash)
        log_activity(outcome: :denied, tool: name, error_message: "invalid_params")
        raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_params"))
      end

      enforce_rate_limit!(name)

      tool_class = available_tool_classes[name]
      unless tool_class
        log_activity(outcome: :denied, tool: name, error_message: "tool_not_available")
        raise Failure.new(Codes::METHOD_NOT_FOUND, t("errors.tool_not_available", tool: name))
      end

      permission = MiniApp::Permission.for_tool(name)
      write = MiniApp::Permission.write?(permission)
      audit = { tool: name, permission: permission, write: write, summary: activity_summary(arguments) }

      unless effective_permissions.include?(permission)
        log_activity(outcome: :denied, error_message: "permission_not_granted", **audit)
        raise Failure.new(Codes::PERMISSION_DENIED, t("errors.permission_denied", permission: MiniApp::Permission.label(permission)),
                          { permission: permission })
      end

      if write && declined
        log_activity(outcome: :declined, **audit)
        raise Failure.new(Codes::DECLINED, t("errors.declined"))
      end

      if write && mini_app.confirm_writes? && !confirmed
        raise Failure.new(Codes::CONFIRMATION_REQUIRED, t("errors.confirmation_required"),
                          { tool: name, permission: permission, summary: confirmation_summary(name),
                            details: MiniApp::WriteDescription.new(user: user, tool: name, arguments: arguments).lines })
      end

      run_tool(tool_class, arguments, audit)
    end

    def run_tool(tool_class, arguments, audit)
      result = tool_class.new(user).call(arguments)
      json = result.to_json

      if tool_reported_failure?(result)
        log_activity(outcome: :error, error_message: tool_error_code(result), **audit)
      else
        log_activity(outcome: :ok, **audit)
      end

      { content: [ { type: "text", text: json } ], structuredContent: JSON.parse(json) }
    rescue => e
      # The exception text is for operators only: it can carry SQL or column
      # definitions, so the app and the activity view get the class name.
      Rails.logger.error "MiniApp bridge tools/call error (#{mini_app.app_key}/#{audit[:tool]}): #{e.class}: #{e.message}"
      log_activity(outcome: :error, error_message: e.class.name, **audit)

      body = { error: t("errors.tool_failed"), tool: audit[:tool] }
      { content: [ { type: "text", text: body.to_json } ], structuredContent: body.deep_stringify_keys, isError: true }
    end

    def tool_reported_failure?(result)
      result.is_a?(Hash) && result.with_indifferent_access[:success] == false
    end

    def tool_error_code(result)
      value = result.with_indifferent_access[:error]
      code = value.is_a?(Hash) ? value.with_indifferent_access[:code] : value
      code.presence&.to_s&.truncate(100) || "tool_error"
    end

    def requested_tool_name(params)
      name = params["name"]
      name.is_a?(String) ? name.truncate(MAX_TOOL_NAME_LENGTH) : nil
    end

    def confirmation_summary(tool_name)
      action = I18n.t("mini_app.bridge.tool_actions.#{tool_name}", default: tool_name.humanize(capitalize: false))
      t("confirm.summary", app: mini_app.name, action: action)
    end

    # Ids and field names are what an admin needs to audit a call; very large
    # payloads are reduced to their keys.
    def activity_summary(arguments)
      json = arguments.to_json
      if json.bytesize <= MAX_LOGGED_ARGUMENTS_BYTES
        { "arguments" => JSON.parse(json) }
      else
        { "argument_keys" => arguments.keys.map(&:to_s).first(50), "truncated" => true }
      end
    end

    # Counts every tools/call for this app and user. Only the first refusal in
    # a window is logged, so a looping app cannot flood its activity view.
    def enforce_rate_limit!(tool_name, bucket: "tools", limit: RATE_LIMIT, rpc_method: "tools/call")
      window = Time.current.to_i / RATE_LIMIT_WINDOW.to_i
      key = "mini_app_bridge:rate:#{bucket}:#{mini_app.id}:#{user.id}:#{window}"
      count = Rails.cache.increment(key, 1, expires_in: RATE_LIMIT_WINDOW * 2)
      return if count.nil? || count <= limit

      log_activity(outcome: :denied, tool: tool_name, error_message: "rate_limited", rpc_method: rpc_method) if count == limit + 1
      raise Failure.new(Codes::RATE_LIMITED, t("errors.rate_limited"), { limit: limit, windowSeconds: RATE_LIMIT_WINDOW.to_i })
    end

    def log_activity(outcome:, tool: nil, permission: nil, write: false, summary: {}, error_message: nil, rpc_method: "tools/call")
      MiniApp::Activity.log!(
        mini_app: mini_app, user: user, rpc_method: rpc_method, outcome: outcome,
        tool: tool, permission: permission, write: write, summary: summary, error_message: error_message
      )
    end

    # --- AI ----------------------------------------------------------------

    # Only advertised to apps that hold ai:use, so nothing else learns which
    # provider the instance uses.
    def ai_capability
      return unless effective_permissions.include?(AI_PERMISSION)

      status = MiniApp::Ai.status
      { available: status[:available], local: status[:local], model: status[:model] }
    end

    # Logged without the prompt or the reply: the activity view records that
    # the app used AI, how much and where, not what it said.
    def ai_complete(params)
      rpc_method = "sure/ai/complete"
      unless effective_permissions.include?(AI_PERMISSION)
        log_activity(outcome: :denied, tool: "ai", permission: AI_PERMISSION, error_message: "permission_not_granted", rpc_method: rpc_method)
        raise Failure.new(Codes::PERMISSION_DENIED, t("errors.permission_denied", permission: MiniApp::Permission.label(AI_PERMISSION)),
                          { permission: AI_PERMISSION })
      end

      prompt = params["prompt"]
      instructions = params["instructions"]
      unless prompt.is_a?(String) && prompt.strip.present? && prompt.length <= MiniApp::Ai::MAX_PROMPT_LENGTH &&
             (instructions.nil? || (instructions.is_a?(String) && instructions.length <= MiniApp::Ai::MAX_INSTRUCTIONS_LENGTH))
        raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_ai_params",
                                                    prompt: MiniApp::Ai::MAX_PROMPT_LENGTH, instructions: MiniApp::Ai::MAX_INSTRUCTIONS_LENGTH))
      end

      enforce_rate_limit!("ai", bucket: "ai", limit: AI_RATE_LIMIT, rpc_method: rpc_method)

      summary = { promptLength: prompt.length, instructionsLength: instructions.to_s.length }
      result = MiniApp::Ai.new(family: mini_app.family).complete(prompt: prompt, instructions: instructions)
      log_activity(outcome: :ok, tool: "ai", permission: AI_PERMISSION, rpc_method: rpc_method,
                   summary: summary.merge(model: result.model, local: result.local, replyLength: result.text.length))
      { text: result.text, model: result.model, local: result.local }
    rescue MiniApp::Ai::Unavailable
      log_activity(outcome: :error, tool: "ai", permission: AI_PERMISSION, error_message: "ai_unavailable", rpc_method: rpc_method)
      raise Failure.new(Codes::AI_UNAVAILABLE, t("errors.ai_unavailable"))
    rescue MiniApp::Ai::Failed, Provider::Error, Faraday::Error, Timeout::Error => e
      Rails.logger.warn("[MiniApp] AI completion failed for #{mini_app.app_key}: #{e.class}: #{e.message}")
      log_activity(outcome: :error, tool: "ai", permission: AI_PERMISSION, error_message: "ai_failed", rpc_method: rpc_method)
      raise Failure.new(Codes::AI_FAILED, t("errors.ai_failed"))
    end

    # --- storage -----------------------------------------------------------

    def storage_get(params)
      record = scoped_records(params).find_by(key: storage_key(params))
      record ? serialize_record(record) : { key: storage_key(params), data: nil, updatedAt: nil }
    end

    def storage_set(params)
      raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_params")) unless params.key?("data")

      record = scoped_records(params).find_or_initialize_by(key: storage_key(params))
      record.data = params["data"]
      unless record.save
        raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_params"), { errors: record.errors.full_messages })
      end

      serialize_record(record)
    end

    def storage_delete(params)
      deleted = scoped_records(params).where(key: storage_key(params)).delete_all
      { deleted: deleted.positive? }
    end

    def storage_list(params)
      limit = storage_limit(params["limit"])
      records = scoped_records(params).with_key_prefix(string_param(params, "prefix", required: false)).ordered

      if (cursor = decode_cursor(params["cursor"]))
        records = records.where("key > ?", cursor)
      end

      page = records.limit(limit + 1).to_a
      more = page.size > limit
      page = page.first(limit)

      {
        items: page.map { |record| serialize_record(record).except(:collection) },
        nextCursor: more ? encode_cursor(page.last.key) : nil
      }
    end

    def scoped_records(params)
      collection = string_param(params, "collection")
      unless collection.match?(MiniApp::Record::COLLECTION_FORMAT)
        raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_collection"))
      end

      mini_app.records.in_collection(collection)
    end

    def storage_key(params)
      key = string_param(params, "key")
      raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_key")) if key.length > MiniApp::Record::MAX_KEY_LENGTH
      key
    end

    def string_param(params, name, required: true)
      value = params[name]
      return value if value.is_a?(String) && value.present?
      return nil if !required && value.nil?

      raise Failure.new(Codes::INVALID_PARAMS, t("errors.missing_param", param: name))
    end

    def storage_limit(value)
      return STORAGE_DEFAULT_LIMIT if value.nil?
      raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_limit")) unless value.is_a?(Integer) && value.positive?

      [ value, STORAGE_MAX_LIMIT ].min
    end

    def encode_cursor(key)
      Base64.urlsafe_encode64(key, padding: false)
    end

    def decode_cursor(cursor)
      return nil if cursor.nil?
      raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_cursor")) unless cursor.is_a?(String)

      Base64.urlsafe_decode64(cursor).force_encoding(Encoding::UTF_8).tap do |key|
        raise ArgumentError unless key.valid_encoding?
      end
    rescue ArgumentError
      raise Failure.new(Codes::INVALID_PARAMS, t("errors.invalid_cursor"))
    end

    def serialize_record(record)
      { collection: record.collection, key: record.key, data: record.data, updatedAt: record.updated_at&.iso8601 }
    end

    # --- responses ---------------------------------------------------------

    def success_response(id, result)
      { jsonrpc: "2.0", id: id, result: result }
    end

    def error_response(id, code, message, data = nil)
      error = { code: code, message: message }
      error[:data] = data if data
      { jsonrpc: "2.0", id: id, error: error }
    end

    def t(key, **options)
      I18n.t("mini_app.bridge.#{key}", **options)
    end
end
