# Settings → Local AI: choose, download and run AI models on this computer.
#
# Only exists inside the Sure Desktop app. The desktop launcher downloads the
# models and runs llama.cpp's server; this page drives it over the app's IPC
# (the desktop_local_ai Stimulus controller), which the launcher grants only to
# its own local Sure server. Local AI applies to the whole installation, so the
# page is for whoever manages instance settings.
class Settings::LocalAisController < ApplicationController
  layout "settings"

  guard_feature unless: -> { sure_desktop? }
  before_action :ensure_instance_settings_manager

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.local_ai"), nil ]
    ]
  end

  private
    def ensure_instance_settings_manager
      return if Current.user.manages_instance_settings?

      redirect_to settings_preferences_path, alert: t("shared.require_admin")
    end
end
