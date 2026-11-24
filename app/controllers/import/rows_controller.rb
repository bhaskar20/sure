class Import::RowsController < ApplicationController
  include ImportGuestGuardable

  before_action :set_import_row
  before_action :require_import_editable!, only: :update

  def update
    # Under the import's lock, so an edit cannot land after publishing has
    # started; see ImportsController#publish.
    locked = false
    @import.with_lock do
      if @import.configuration_locked?
        locked = true
      else
        @row.update_and_sync(row_params.merge(counterparty_params))
      end
    end
    return redirect_to(import_path(@import), alert: t("imports.configuration_locked")) if locked

    redirect_to import_row_path(@row.import, @row)
  end

  def show
  end

  private
    def row_params
      params.require(:import_row).permit(:type, :account, :date, :qty, :ticker, :price, :amount, :currency, :name, :category, :tags, :entity_type, :notes, :category_color, :category_classification, :category_parent, :category_icon)
    end

    # The Counterparty column is a preview feature of statement imports. An
    # account can only be picked if the reviewer may write to it, since
    # publishing links a transaction there.
    def counterparty_params
      choice = params.require(:import_row).permit(:counterparty_choice)[:counterparty_choice].to_s
      return {} if choice.blank? || !@import.is_a?(PdfImport) || !preview_features_enabled?

      if choice.start_with?("account:")
        return {} unless @import.counterparty_accounts_for(Current.user).exists?(id: choice.delete_prefix("account:"))
      elsif choice.start_with?("untracked:")
        return {} unless Current.family.own_untracked_accounts.exists?(id: choice.delete_prefix("untracked:"))
      end

      { counterparty_choice: choice }
    end

    def set_import_row
      @import = Current.family.imports.find(params[:import_id])
      @row = @import.rows.find(params[:id])
    end
end
