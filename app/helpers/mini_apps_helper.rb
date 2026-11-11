module MiniAppsHelper
  OUTCOME_TONES = { "ok" => :success, "denied" => :error, "declined" => :warning, "error" => :error }.freeze

  def mini_app_outcome_tone(activity)
    OUTCOME_TONES.fetch(activity.outcome, :neutral)
  end
end
