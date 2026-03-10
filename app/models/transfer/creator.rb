class Transfer::Creator
  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:, conversion_amount: nil, conversion_currency: nil)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
    @conversion_amount = conversion_amount.present? ? conversion_amount.to_d.nonzero? : nil
    @conversion_currency = conversion_currency
  end

  def create
    transfer = Transfer.new(
      inflow_transaction: inflow_transaction,
      outflow_transaction: outflow_transaction,
      status: "confirmed"
    )

    if transfer.save
      create_transfer_fee_entry if should_create_transfer_fee?
      source_account.sync_later
      destination_account.sync_later
    end

    transfer
  end

  private
    attr_reader :family, :source_account, :destination_account, :date, :amount, :conversion_amount, :conversion_currency

    def outflow_transaction
      name = "#{name_prefix} to #{destination_account.name}"
      kind = outflow_transaction_kind

      Transaction.new(
        kind: kind,
        category: (investment_contributions_category if kind == "investment_contribution"),
        entry: source_account.entries.build(
          amount: amount.abs,
          currency: source_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    def investment_contributions_category
      source_account.family.investment_contributions_category
    end

    def inflow_transaction
      name = "#{name_prefix} from #{source_account.name}"

      Transaction.new(
        kind: "funds_movement",
        entry: destination_account.entries.build(
          amount: inflow_converted_money.amount.abs * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    # If destination account has different currency, its transaction should show up as converted
    # Future improvement: instead of a 1:1 conversion fallback, add a UI/UX flow for missing rates
    def inflow_converted_money
      if conversion_amount.present?
        Money.new(conversion_amount.abs, destination_account.currency)
      else
        Money.new(amount.abs, source_account.currency)
             .exchange_to(
               destination_account.currency,
               date: date,
               fallback_rate: 1.0
            )
      end
    end

    # The "expense" side of a transfer is treated different in analytics based on where it goes.
    def outflow_transaction_kind
      if destination_account.loan?
        "loan_payment"
      elsif destination_account.liability?
        "cc_payment"
      elsif destination_is_investment? && !source_is_investment?
        "investment_contribution"
      else
        "funds_movement"
      end
    end

    def destination_is_investment?
      destination_account.investment? || destination_account.crypto?
    end

    def source_is_investment?
      source_account.investment? || source_account.crypto?
    end

    def should_create_transfer_fee?
      conversion_amount.present?
    end

    def create_transfer_fee_entry
      # Market value of what was received, in source account currency
      market_value = Money.new(conversion_amount.abs, destination_account.currency)
                          .exchange_to(source_account.currency, date: date, fallback_rate: nil)

      return unless market_value

      fee_amount = amount.abs - market_value.amount.abs
      return unless fee_amount > 0.001

      fees_category = family.categories.find_by(name: "Fees")

      source_account.entries.create!(
        name: "Conversion fee (#{source_account.currency} → #{destination_account.currency})",
        date: date,
        amount: fee_amount,
        currency: source_account.currency,
        user_modified: true,
        entryable: Transaction.new(
          kind: "standard",
          category: fees_category
        )
      )
    rescue Money::ConversionError
      Rails.logger.warn("Could not create transfer conversion fee: no exchange rate for #{destination_account.currency}→#{source_account.currency} on #{date}")
    end

    def name_prefix
      if destination_account.liability?
        "Payment"
      else
        "Transfer"
      end
    end
end
