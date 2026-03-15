class AddConversionFieldsToTransactions < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :conversion_amount, :decimal, precision: 19, scale: 4
    add_column :transactions, :conversion_currency, :string
  end
end
