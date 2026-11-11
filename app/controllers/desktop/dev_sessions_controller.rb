# Sure Desktop development builds only: lets the launcher's window list the
# accounts in the dev data and sign in as one with a click (human dev mode).
#
# Everything here answers 404 unless the desktop launcher started this server
# with SURE_DESKTOP_DEV_LOGIN_TOKEN, which only debug builds do, freshly on each
# launch, and the request carries that same token.
class Desktop::DevSessionsController < ApplicationController
  skip_authentication
  skip_forgery_protection only: :create
  before_action :require_dev_login_token

  def index
    users = User.includes(:family).order(:email)
    render json: users.map { |user|
      { email: user.email, name: user.display_name, role: user.role, family: user.family&.name.to_s }
    }
  end

  def create
    user = User.find_by(email: params[:email].to_s)
    return head :not_found unless user && create_session_for(user)

    redirect_to root_path
  end

  private
    def require_dev_login_token
      expected = ENV["SURE_DESKTOP_DEV_LOGIN_TOKEN"].to_s
      given = params[:token].to_s
      return if sure_desktop? && expected.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)

      head :not_found
    end
end
