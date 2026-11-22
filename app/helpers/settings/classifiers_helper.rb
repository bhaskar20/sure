module Settings::ClassifiersHelper
  # One auto-submitting form per Settings → Classifier section: only its
  # fields are sent, and the controller merges them into the stored settings.
  # A helper, not a layout partial, so t(".key") inside still resolves
  # against the section's own partial. Its builder names fields
  # bayes_settings[...], for DS::Select.
  def classifier_section_form(&block)
    form_with url: settings_classifier_path, method: :patch, scope: :bayes_settings, class: "space-y-4",
              data: { controller: "auto-submit-form", auto_submit_form_trigger_event_value: "change" }, &block
  end

  # Where an AI rule's transactions would go: the model the router picks for
  # its feature, and whether that's Local AI on this computer or a server
  # elsewhere.
  def ai_classifier_provider_hint(action_type)
    feature = Family::AI_CLASSIFIER_FEATURES.fetch(action_type)
    model = Ai.plan(feature, family: Current.family, user: Current.user)&.model
    return t("settings.classifiers.ai.#{sure_desktop? ? "provider_none_desktop" : "provider_none"}") unless model

    if model.endpoint.local?
      t("settings.classifiers.ai.provider_local", model: model.name)
    else
      t("settings.classifiers.ai.provider_cloud", model: model.name, endpoint: ai_endpoint_label(model.endpoint))
    end
  end

  private
    def ai_endpoint_label(endpoint)
      host = URI.parse(endpoint.base_url.to_s).host if endpoint.base_url.present?
      host.presence || endpoint.name.to_s.humanize
    rescue URI::InvalidURIError
      endpoint.name.to_s.humanize
    end
end
