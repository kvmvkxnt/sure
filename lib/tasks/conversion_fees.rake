namespace :conversion_fees do
  desc "Backfill conversion fee entries skipped due to missing exchange rates"
  task backfill: :environment do
    skipped = Transaction.where("extra @> ?", { conversion_fee_skipped: true }.to_json)
    total = skipped.count
    puts "Found #{total} transactions with skipped conversion fees"
    succeeded = 0
    failed = 0

    skipped.find_each do |txn|
      txn.create_conversion_fee_entry
      # Check if it succeeded (flag would be cleared or fee entry created)
      if txn.reload.extra["conversion_fee_entry_id"].present?
        succeeded += 1
        puts "  ✓ #{txn.id}"
      else
        failed += 1
        puts "  ✗ #{txn.id} (still no rate available)"
      end
    rescue => e
      failed += 1
      puts "  ✗ #{txn.id}: #{e.message}"
    end

    puts "Done: #{succeeded} succeeded, #{failed} still pending"
  end
end
