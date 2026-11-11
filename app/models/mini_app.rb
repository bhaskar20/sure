# A third-party app installed into one family. Its UI runs in a sandboxed
# frame and reaches family data only through MiniApp::Bridge, limited to the
# permissions an admin granted here.
class MiniApp < ApplicationRecord
  # Base for install-time failures; `errors` holds localized messages.
  class Error < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super(@errors.join(" "))
    end
  end

  SOURCES = %w[bundle dev_server].freeze
  STATUSES = %w[enabled disabled].freeze
  WRITE_POLICIES = %w[confirm allow].freeze
  FRAME_TOKEN_PURPOSE = :mini_app_frame
  FRAME_TOKEN_EXPIRY = 12.hours

  belongs_to :family
  belongs_to :installed_by, class_name: "User", optional: true
  has_many :assets, class_name: "MiniApp::Asset", dependent: :delete_all
  has_many :records, class_name: "MiniApp::Record", dependent: :delete_all
  has_many :activities, class_name: "MiniApp::Activity", dependent: :delete_all

  validates :app_key, presence: true, format: { with: MiniApp::Manifest::ID_FORMAT },
                      uniqueness: { scope: :family_id }
  validates :name, :version, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :write_policy, inclusion: { in: WRITE_POLICIES }
  validates :dev_url, presence: true, if: :dev_server?
  validate :granted_permissions_must_be_requested

  scope :enabled, -> { where(status: "enabled") }
  scope :alphabetically, -> { order(:name) }

  class << self
    # `upgrade: true` is the admin's explicit go-ahead to replace an installed
    # app with the same manifest id; without it a clashing id is refused.
    def install_bundle!(family:, user:, io:, upgrade: false)
      package = MiniApp::Package.new(io).read!
      install!(family: family, user: user, manifest: package[:manifest], source: "bundle", upgrade: upgrade,
               bundle_sha256: package[:sha256], assets: package[:assets])
    end

    def install_dev_server!(family:, user:, url:, upgrade: false)
      raise MiniApp::DevServer::Invalid.new([ I18n.t("mini_app.dev_server.errors.unavailable") ]) unless dev_mode_available?

      server = MiniApp::DevServer.new(url)
      install!(family: family, user: user, manifest: server.fetch_manifest!, source: "dev_server", upgrade: upgrade,
               dev_url: server.base_url, assets: [])
    end

    def find_by_frame_token(token)
      return nil if token.blank?
      find_signed(token, purpose: FRAME_TOKEN_PURPOSE)
    end

    # Loading an app from a local URL is a development tool; hosted installs
    # never contact a developer's machine.
    def dev_mode_available?
      Rails.env.development? || Rails.env.test? || Rails.application.config.app_mode.self_hosted?
    end

    private
      # Creates the app or, when the admin confirmed it, upgrades the one with
      # the same manifest id. Manifest ids are neither signed nor namespaced,
      # so an upgrade is never implied: new code runs under the old app's
      # storage and grants. An upgrade replaces files and manifest, keeps
      # storage, activity and status, drops grants the new manifest no longer
      # requests, and resets the write policy to `confirm` so the new code
      # cannot write unseen. Switching between bundle and dev server in place
      # is refused.
      def install!(family:, user:, manifest:, source:, assets:, upgrade:, bundle_sha256: nil, dev_url: nil)
        transaction do
          app = family.mini_apps.lock.find_or_initialize_by(app_key: manifest.id)
          if app.new_record?
            app.installed_by = user
          else
            ensure_upgrade_allowed!(app, source: source, upgrade: upgrade)
            app.write_policy = "confirm"
          end
          app.assign_attributes(
            name: manifest.name,
            version: manifest.version,
            description: manifest.description,
            icon: manifest.icon,
            manifest: manifest.to_h,
            source: source,
            dev_url: dev_url,
            bundle_sha256: bundle_sha256
          )
          app.granted_permissions = app.granted_permissions & app.requested_permissions
          app.save!

          app.assets.delete_all
          assets.each do |asset|
            app.assets.create!(path: asset[:path], content_type: asset[:content_type], content: asset[:content])
          end

          app
        end
      end

      def ensure_upgrade_allowed!(app, source:, upgrade:)
        unless upgrade
          raise MiniApp::Error.new([ I18n.t("mini_app.install.errors.already_installed", id: app.app_key, name: app.name) ])
        end
        return if app.source == source

        raise MiniApp::Error.new([ I18n.t("mini_app.install.errors.source_changed", name: app.name) ])
      end
  end

  def enabled?
    status == "enabled"
  end

  def disabled?
    status == "disabled"
  end

  def enable!
    update!(status: "enabled")
  end

  def disable!
    update!(status: "disabled")
  end

  def dev_server?
    source == "dev_server"
  end

  def bundle?
    source == "bundle"
  end

  def confirm_writes?
    write_policy != "allow"
  end

  # Catalog permissions the manifest asks for, in manifest order.
  def requested_permissions
    Array(manifest&.dig("permissions")) & MiniApp::Permission.all
  end

  def granted?(permission)
    granted_permissions.include?(permission.to_s)
  end

  def update_grants!(permissions:, write_policy: self.write_policy)
    update!(
      granted_permissions: Array(permissions).map(&:to_s) & requested_permissions,
      write_policy: write_policy.presence || self.write_policy
    )
  end

  # What this user may do through the app right now. Guests never write,
  # whatever is granted, and users outside the family get nothing.
  def effective_permissions_for(user)
    return [] if user.nil? || user.family_id != family_id

    permissions = granted_permissions & MiniApp::Permission.all
    permissions = permissions.reject { |permission| MiniApp::Permission.write?(permission) } if user.guest?
    permissions
  end

  def entry_path
    manifest&.dig("entry").presence || MiniApp::Manifest::DEFAULT_ENTRY
  end

  def network_origins
    Array(manifest&.dig("network"))
  end

  def frame_token
    signed_id(purpose: FRAME_TOKEN_PURPOSE, expires_in: FRAME_TOKEN_EXPIRY)
  end

  def total_asset_bytes
    assets.sum(:byte_size)
  end

  private
    def granted_permissions_must_be_requested
      return if (granted_permissions - requested_permissions).empty?
      errors.add(:granted_permissions, :not_requested)
    end
end
