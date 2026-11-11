class MiniAppsController < ApplicationController
  before_action :require_preview_features!
  before_action :require_admin!, only: %i[new create consent update destroy activity]
  before_action :set_mini_app, except: %i[index new create]

  def index
    @mini_apps = Current.family.mini_apps.alphabetically
    @mini_apps = @mini_apps.enabled unless Current.user.admin?
    @dev_mode_available = MiniApp.dev_mode_available?
  end

  def new
    @dev_mode_available = MiniApp.dev_mode_available?
  end

  def show
    return redirect_to(mini_apps_path, alert: t(".disabled")) unless @mini_app.enabled?

    @mini_app.update_column(:last_opened_at, Time.current)
    @frame_src = frame_src_for(@mini_app)
  end

  def create
    mini_app = install_from_params
    return redirect_to(mini_apps_path, alert: t(".missing_source")) unless mini_app

    redirect_to consent_mini_app_path(mini_app), notice: t(".installed", name: mini_app.name)
  rescue MiniApp::Error => e
    redirect_to mini_apps_path, alert: e.errors.join(" ")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to mini_apps_path, alert: e.record.errors.full_messages.to_sentence
  end

  def consent
    @requested_permissions = @mini_app.requested_permissions
    @ai_status = MiniApp::Ai.status if @requested_permissions.include?(MiniApp::Bridge::AI_PERMISSION)
  end

  def update
    attrs = mini_app_params

    if attrs.key?(:granted_permissions) || attrs.key?(:write_policy)
      permissions = attrs.key?(:granted_permissions) ? Array(attrs[:granted_permissions]).compact_blank : @mini_app.granted_permissions
      @mini_app.update_grants!(permissions: permissions, write_policy: attrs[:write_policy])
    end

    case attrs[:status]
    when "enabled" then @mini_app.enable!
    when "disabled" then @mini_app.disable!
    end

    if attrs.key?(:granted_permissions) && @mini_app.enabled?
      redirect_to mini_app_path(@mini_app), notice: t(".saved")
    else
      redirect_to mini_apps_path, notice: t(".saved")
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to mini_apps_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    name = @mini_app.name
    @mini_app.destroy!
    redirect_to mini_apps_path, notice: t(".removed", name: name)
  end

  def activity
    @activities = @mini_app.activities.includes(:user).recent(100)
  end

  # JSON-RPC from the host page on behalf of the sandboxed frame. The bridge
  # checks the app's status and grants on every call.
  def bridge
    message = request.request_parameters["message"]
    message = message.to_hash if message.respond_to?(:to_hash)

    response = MiniApp::Bridge.new(mini_app: @mini_app, user: Current.user).handle(
      message,
      confirmed: request.request_parameters["confirmed"] == true,
      declined: request.request_parameters["declined"] == true
    )
    render json: response
  end

  private
    def set_mini_app
      @mini_app = Current.family.mini_apps.find(params[:id])
    end

    def mini_app_params
      params.fetch(:mini_app, {}).permit(:status, :write_policy, granted_permissions: [])
    end

    def install_from_params
      if params[:bundle].respond_to?(:read)
        MiniApp.install_bundle!(family: Current.family, user: Current.user, io: params[:bundle], upgrade: upgrade_requested?)
      elsif params[:dev_url].present? && MiniApp.dev_mode_available?
        MiniApp.install_dev_server!(family: Current.family, user: Current.user, url: params[:dev_url], upgrade: upgrade_requested?)
      end
    end

    def upgrade_requested?
      params[:upgrade] == "1"
    end

    def frame_src_for(mini_app)
      if mini_app.dev_server?
        "#{mini_app.dev_url}#{mini_app.entry_path}"
      else
        mini_app_frame_url(token: mini_app.frame_token, path: mini_app.entry_path)
      end
    end
end
