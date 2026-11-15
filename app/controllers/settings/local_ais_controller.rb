# Settings → Local AI: choose, download and run AI models on this computer.
#
# Only exists inside the Sure Desktop app. The desktop launcher downloads the
# models and runs llama.cpp's server; this page drives it over the app's IPC
# (the desktop_local_ai Stimulus controller), which the launcher grants only to
# its own local Sure server. Local AI applies to the whole installation; anyone
# signed in to this computer's Sure can manage it.
class Settings::LocalAisController < ApplicationController
  layout "settings"

  guard_feature unless: -> { sure_desktop? }

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.local_ai"), nil ]
    ]
  end
end
