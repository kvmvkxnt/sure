class Transaction < ApplicationRecord
  include Entryable, Transferable, Ruleable

  belongs_to :category, optional: true
  belongs_to :merchant, optional: true

  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings

  accepts_nested_attributes_for :taggings, allow_destroy: true

  after_save :clear_merchant_unlinked_association, if: :merchant_id_previously_changed?
  before_destroy :destroy_conversion_fee_entry

  enum :kind, {
    standard: "standard", # A regular transaction, included in budget analytics
    funds_movement: "funds_movement", # Movement of funds between accounts, excluded from budget analytics
    cc_payment: "cc_payment", # A CC payment, excluded from budget analytics (CC payments offset the sum of expense transactions)
    loan_payment: "loan_payment", # A payment to a Loan account, treated as an expense in budgets
    one_time: "one_time", # A one-time expense/income, excluded from budget analytics
    investment_contribution: "investment_contribution" # Transfer to investment/crypto account, treated as an expense in budgets
  }

  # All kinds where money moves between accounts (transfer? returns true).
  # Used for search filters, rule conditions, and UI display.
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment investment_contribution].freeze

  # Kinds excluded from budget/income-statement analytics.
  # loan_payment and investment_contribution are intentionally NOT here —
  # they represent real cash outflow from a budgeting perspective.
  BUDGET_EXCLUDED_KINDS = %w[funds_movement one_time cc_payment].freeze

  # All valid investment activity labels (for UI dropdown)
  ACTIVITY_LABELS = [
    "Buy", "Sell", "Sweep In", "Sweep Out", "Dividend", "Reinvestment",
    "Interest", "Fee", "Transfer", "Contribution", "Withdrawal", "Exchange", "Other"
  ].freeze

  # Internal movement labels that should be excluded from budget (auto cash management)
  INTERNAL_MOVEMENT_LABELS = [ "Transfer", "Sweep In", "Sweep Out", "Exchange" ].freeze

  # Pending transaction scopes - filter based on provider pending flags in extra JSONB
  # Works with any provider that stores pending status in extra["provider_name"]["pending"]
  scope :pending, -> {
    where(<<~SQL.squish)
      (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
      OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
      OR (transactions.extra -> 'lunchflow' ->> 'pending')::boolean = true
    SQL
  }

  scope :excluding_pending, -> {
    where(<<~SQL.squish)
      (transactions.extra -> 'simplefin' ->> 'pending')::boolean IS DISTINCT FROM true
      AND (transactions.extra -> 'plaid' ->> 'pending')::boolean IS DISTINCT FROM true
      AND (transactions.extra -> 'lunchflow' ->> 'pending')::boolean IS DISTINCT FROM true
    SQL
  }

  # Family-scoped query for Enrichable#clear_ai_cache
  def self.family_scope(family)
    joins(entry: :account).where(accounts: { family_id: family.id })
  end

  # Overarching grouping method for all transfer-type transactions
  def transfer?
    TRANSFER_KINDS.include?(kind)
  end

  def set_category!(category)
    if category.is_a?(String)
      category = entry.account.family.categories.find_or_create_by!(
        name: category
      )
    end

    update!(category: category)
  end

  def pending?
    extra_data = extra.is_a?(Hash) ? extra : {}
    ActiveModel::Type::Boolean.new.cast(extra_data.dig("simplefin", "pending")) ||
      ActiveModel::Type::Boolean.new.cast(extra_data.dig("plaid", "pending")) ||
      ActiveModel::Type::Boolean.new.cast(extra_data.dig("lunchflow", "pending"))
  rescue
    false
  end

  # Potential duplicate matching methods
  # These help users review and resolve fuzzy-matched pending/posted pairs

  def has_potential_duplicate?
    potential_posted_match_data.present? && !potential_duplicate_dismissed?
  end

  def potential_duplicate_entry
    return nil unless has_potential_duplicate?
    Entry.find_by(id: potential_posted_match_data["entry_id"])
  end

  def potential_duplicate_reason
    potential_posted_match_data&.dig("reason")
  end

  def potential_duplicate_confidence
    potential_posted_match_data&.dig("confidence") || "medium"
  end

  def low_confidence_duplicate?
    potential_duplicate_confidence == "low"
  end

  def potential_duplicate_posted_amount
    potential_posted_match_data&.dig("posted_amount")&.to_d
  end

  def potential_duplicate_dismissed?
    potential_posted_match_data&.dig("dismissed") == true
  end

  # Merge this pending transaction with its suggested posted match
  # This DELETES the pending entry since the posted version is canonical
  def merge_with_duplicate!
    return false unless has_potential_duplicate?

    posted_entry = potential_duplicate_entry
    return false unless posted_entry

    pending_entry_id = entry.id
    pending_entry_name = entry.name

    # Delete this pending entry completely (no need to keep it around)
    entry.destroy!

    Rails.logger.info("User merged pending entry #{pending_entry_id} (#{pending_entry_name}) with posted entry #{posted_entry.id}")
    true
  end

  # Dismiss the duplicate suggestion - user says these are NOT the same transaction
  def dismiss_duplicate_suggestion!
    return false unless potential_posted_match_data.present?

    updated_extra = (extra || {}).deep_dup
    updated_extra["potential_posted_match"]["dismissed"] = true
    update!(extra: updated_extra)

    Rails.logger.info("User dismissed duplicate suggestion for entry #{entry.id}")
    true
  end

  # Clear the duplicate suggestion entirely
  def clear_duplicate_suggestion!
    return false unless potential_posted_match_data.present?

    updated_extra = (extra || {}).deep_dup
    updated_extra.delete("potential_posted_match")
    update!(extra: updated_extra)
    true
  end

  def has_conversion_data?
    conversion_amount.present?
  end

  def create_conversion_fee_entry
    account = entry.account
    account_currency = account.currency
    operation_currency = entry.currency
    date = entry.date

    market_value = Money.new(entry.amount.abs, operation_currency)
                        .exchange_to(account_currency, date: date, fallback_rate: nil)

    return unless market_value

    fee_amount = conversion_amount.abs - market_value.amount.abs
    return unless fee_amount > 0.001

    fees_category = account.family.categories.find_by(name: "Fees")

    fee_entry = account.entries.create!(
      name: "Conversion fee for: #{entry.name}",
      date: date,
      amount: fee_amount,
      currency: account_currency,
      user_modified: true,
      entryable: Transaction.new(
        kind: "standard",
        category: fees_category
      )
    )

    # Store reference to fee entry so we can sync/delete it later
    update_column(:extra, (extra || {}).merge("conversion_fee_entry_id" => fee_entry.id))
  rescue Money::ConversionError
    Rails.logger.warn("Could not create conversion fee for transaction #{id}: no exchange rate for #{operation_currency}→#{account_currency} on #{date}")
  end

  def sync_conversion_fee_entry
    destroy_conversion_fee_entry

    if has_conversion_data?
      create_conversion_fee_entry
    end
  end

  def destroy_conversion_fee_entry
    fee_entry_id = extra&.dig("conversion_fee_entry_id")
    return unless fee_entry_id

    Entry.find_by(id: fee_entry_id)&.destroy
    update_column(:extra, (extra || {}).except("conversion_fee_entry_id"))
  end

  def conversion_fee_relevant_changes?
    entry.saved_change_to_amount? ||
    entry.saved_change_to_currency? ||
    entry.saved_change_to_name? ||
    saved_change_to_conversion_amount?
  end

  private

    def potential_posted_match_data
      return nil unless extra.is_a?(Hash)
      extra["potential_posted_match"]
    end

    def clear_merchant_unlinked_association
      return unless merchant_id.present? && merchant.is_a?(ProviderMerchant)

      family = entry&.account&.family
      return unless family

      FamilyMerchantAssociation.where(family: family, merchant: merchant).delete_all
    end
end
