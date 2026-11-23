# The family's own accounts outside Sure that statement lines can be traced to
# (FR-004). A preview feature, managed from settings and created from the
# statement review.
class OwnUntrackedAccountsController < ApplicationController
  include ImportGuestGuardable

  before_action :require_preview_features!
  before_action :require_non_guest!, except: :index
  before_action :set_own_untracked_account, only: %i[edit update destroy]
  before_action :set_import_row, only: %i[new create]

  def index
    @own_untracked_accounts = Current.family.own_untracked_accounts.alphabetically.to_a
    render layout: "settings"
  end

  def new
    @own_untracked_account = Current.family.own_untracked_accounts.new
  end

  def create
    @own_untracked_account = Current.family.own_untracked_accounts.new(own_untracked_account_params)
    return create_for_row if @row

    if @own_untracked_account.save
      redirect_to own_untracked_accounts_path, notice: t(".created")
    else
      redirect_back_or_to (@row ? import_clean_path(@row.import) : own_untracked_accounts_path),
        alert: t(".error", error: @own_untracked_account.errors.full_messages.to_sentence)
    end
  end

  def edit
  end

  def update
    if @own_untracked_account.update(own_untracked_account_params)
      redirect_to own_untracked_accounts_path, notice: t(".updated")
    else
      redirect_to own_untracked_accounts_path, alert: t(".error", error: @own_untracked_account.errors.full_messages.to_sentence)
    end
  end

  def destroy
    @own_untracked_account.destroy!
    redirect_to own_untracked_accounts_path, notice: t(".deleted")
  end

  private
    def set_own_untracked_account
      @own_untracked_account = Current.family.own_untracked_accounts.find(params[:id])
    end

    # Opened from a statement review row: the new account is assigned to that
    # row, under the same rules as picking it in the review.
    def set_import_row
      return if params[:import_row_id].blank?

      @row = Import::Row.joins(:import).where(imports: { family_id: Current.family.id, type: "PdfImport" }).find(params[:import_row_id])
      @import = @row.import
    end

    # Creates the account and assigns it to the row together, under the
    # import's lock, or neither when the review is closed.
    def create_for_row
      saved = locked = false
      @import.with_lock do
        if @import.configuration_locked? || !@import.editable_by?(Current.user)
          locked = true
        elsif (saved = @own_untracked_account.save)
          @row.update_and_sync(counterparty_choice: "untracked:#{@own_untracked_account.id}")
        end
      end

      if locked
        redirect_to import_path(@import), alert: t(".locked")
      elsif saved
        redirect_to import_clean_path(@import), notice: t(".created")
      else
        redirect_to import_clean_path(@import), alert: t(".error", error: @own_untracked_account.errors.full_messages.to_sentence)
      end
    end

    def own_untracked_account_params
      params.require(:own_untracked_account).permit(:name)
    end
end
