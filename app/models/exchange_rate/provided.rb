module ExchangeRate::Provided
  extend ActiveSupport::Concern

  class_methods do
    def provider
      provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
      registry = Provider::Registry.for_concept(:exchange_rates)
      registry.get_provider(provider.to_sym)
    end

    def fallback_provider
      @fallback_provider ||= Provider::Cbu.new
    end

    NEAREST_RATE_LOOKBACK_DAYS = 5

    def find_or_fetch_rate(from:, to:, date: Date.current, cache: true)
      rate = find_by(from_currency: from, to_currency: to, date: date)
      return rate if rate.present?

      nearest = where(from_currency: from, to_currency: to)
                  .where(date: (date - NEAREST_RATE_LOOKBACK_DAYS)..date)
                  .order(date: :desc)
                  .first
      return nearest if nearest.present?

      # Try primary provider first, then CBU as fallback for UZS pairs
      response = nil
      response = provider.fetch_exchange_rate(from: from, to: to, date: date) if provider.present?

      if (response.nil? || !response.success?) && Provider::Cbu.supports_pair?(from, to)
        Rails.logger.info("[ExchangeRate] Primary provider failed for #{from}/#{to}, trying CBU fallback")
        response = fallback_provider.fetch_exchange_rate(from: from, to: to, date: date)
      end

      return nil unless response&.success?

      rate = response.data
      begin
        ExchangeRate.find_or_create_by!(
          from_currency: rate.from,
          to_currency: rate.to,
          date: rate.date
        ) do |exchange_rate|
          exchange_rate.rate = rate.rate
        end if cache
      rescue ActiveRecord::RecordNotUnique
        ExchangeRate.find_by!(
          from_currency: rate.from,
          to_currency: rate.to,
          date: rate.date
        ) if cache
      end
      rate
    end

    def rates_for(currencies, to:, date: Date.current)
      currencies.uniq.each_with_object({}) do |currency, map|
        rate = find_or_fetch_rate(from: currency, to: to, date: date)
        map[currency] = rate&.rate || 1
      end
    end

    def import_provider_rates(from:, to:, start_date:, end_date:, clear_cache: false)
      primary = provider

      # Try primary provider
      if primary.present?
        count = ExchangeRate::Importer.new(
          exchange_rate_provider: primary,
          from: from,
          to: to,
          start_date: start_date,
          end_date: end_date,
          clear_cache: clear_cache
        ).import_provider_rates

        return count if count.to_i > 0
      end

      # Fall back to CBU for UZS pairs if primary returned nothing
      if Provider::Cbu.supports_pair?(from, to)
        Rails.logger.info("[ExchangeRate] Primary provider returned no rates for #{from}/#{to}, trying CBU fallback")
        ExchangeRate::Importer.new(
          exchange_rate_provider: fallback_provider,
          from: from,
          to: to,
          start_date: start_date,
          end_date: end_date,
          clear_cache: clear_cache
        ).import_provider_rates
      else
        Rails.logger.warn("No provider configured for ExchangeRate.import_provider_rates")
        0
      end
    end
  end
end
