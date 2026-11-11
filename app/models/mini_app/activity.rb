# One bridge call made by a mini app, kept so the family can see what each app
# did, tried to do, or was refused.
class MiniApp::Activity < ApplicationRecord
  OUTCOMES = %w[ok denied declined error].freeze
  MAX_ERROR_MESSAGE_LENGTH = 1_000
  DEFAULT_RECENT_LIMIT = 50

  belongs_to :mini_app
  belongs_to :user, optional: true

  validates :rpc_method, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :recent, ->(limit = DEFAULT_RECENT_LIMIT) { order(created_at: :desc).limit(limit) }
  scope :writes, -> { where(write: true) }

  class << self
    def log!(mini_app:, rpc_method:, outcome:, user: nil, tool: nil, permission: nil, write: false, summary: {}, error_message: nil)
      create!(
        mini_app: mini_app,
        user: user,
        rpc_method: rpc_method,
        tool: tool,
        permission: permission,
        outcome: outcome.to_s,
        write: write,
        summary: summary || {},
        error_message: error_message&.to_s&.truncate(MAX_ERROR_MESSAGE_LENGTH)
      )
    end
  end

  OUTCOMES.each do |name|
    define_method("#{name}?") { outcome == name }
  end
end
