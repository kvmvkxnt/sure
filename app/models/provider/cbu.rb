# Provider::Cbu
#
# Exchange rate provider using the Central Bank of Uzbekistan (CBU) public API.
# https://cbu.uz/en/arkhiv-kursov-valyut/json/
#
# CBU publishes daily official rates for all major currencies vs UZS.
# Used as a fallback when the primary provider (Yahoo Finance) cannot fetch
# a UZS pair — Yahoo Finance does not support UZS.
#
# Rate format: how many UZS per 1 unit of foreign currency (or per Nominal units).
# Example: USD rate = 12275.95 means 1 USD = 12275.95 UZS
#
class Provider::Cbu < Provider
  include ExchangeRateConcept

  Error = Class.new(Provider::Error)

  BASE_URL = "https://cbu.uz"
  SUPPORTED_BASE_CURRENCY = "UZS"

  def initialize
    @cache_prefix = "cbu"
  end

  def healthy?
    response = client.get("#{BASE_URL}/en/arkhiv-kursov-valyut/json/USD/#{Date.current.strftime("%d.%m.%Y")}/#{Date.current.strftime("%d.%m.%Y")}/")
    JSON.parse(response.body).is_a?(Array)
  rescue
    false
  end

  # Returns true if this provider can handle the given currency pair.
  # CBU only covers pairs involving UZS.
  def self.supports_pair?(from, to)
    from == SUPPORTED_BASE_CURRENCY || to == SUPPORTED_BASE_CURRENCY
  end

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      rates_response = fetch_exchange_rates(from: from, to: to, start_date: date - 10.days, end_date: date)
      raise Error, "No rates returned" unless rates_response.success? && rates_response.data.any?

      target = rates_response.data.select { |r| r.date <= date }.max_by(&:date)
      raise Error, "No rate found for #{from}/#{to} on or before #{date}" unless target

      target
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      raise Error, "CBU only supports pairs involving UZS" unless self.class.supports_pair?(from, to)

      return generate_same_currency_rates(from, to, start_date, end_date) if from == to

      # Determine which currency is the foreign one (non-UZS side)
      foreign_currency = from == SUPPORTED_BASE_CURRENCY ? to : from
      invert = from == SUPPORTED_BASE_CURRENCY # UZS→XXX means we invert the rate

      raw_rates = fetch_cbu_rates(foreign_currency, start_date, end_date)
      raise Error, "No data returned from CBU for #{foreign_currency}" if raw_rates.empty?

      rates = raw_rates.filter_map do |entry|
        date = parse_cbu_date(entry["Date"])
        next unless date

        nominal = entry["Nominal"].to_f
        rate_value = entry["Rate"].to_f
        next if nominal <= 0 || rate_value <= 0

        # CBU rate: rate_value UZS per nominal units of foreign currency
        # e.g. Nominal=1, Rate=12275 means 1 USD = 12275 UZS
        uzs_per_unit = rate_value / nominal

        final_rate = invert ? (1.0 / uzs_per_unit).round(10) : uzs_per_unit

        Rate.new(date: date, from: from, to: to, rate: final_rate)
      end

      rates.sort_by(&:date)
    end
  end

  private

    def fetch_cbu_rates(currency, start_date, end_date)
      cache_key = "#{@cache_prefix}_#{currency}_#{start_date}_#{end_date}"
      cached = Rails.cache.read(cache_key)
      return cached if cached.present?

      from_str = start_date.strftime("%d.%m.%Y")
      to_str   = end_date.strftime("%d.%m.%Y")

      response = client.get("#{BASE_URL}/en/arkhiv-kursov-valyut/json/#{currency}/#{from_str}/#{to_str}/")
      data = JSON.parse(response.body)

      raise Error, "Unexpected response format" unless data.is_a?(Array)

      Rails.cache.write(cache_key, data, expires_in: 6.hours)
      data
    rescue Faraday::Error => e
      raise Error, "CBU request failed: #{e.message}"
    rescue JSON::ParserError => e
      raise Error, "CBU returned invalid JSON: #{e.message}"
    end

    def parse_cbu_date(date_str)
      # CBU returns dates as "DD.MM.YYYY"
      Date.strptime(date_str, "%d.%m.%Y")
    rescue ArgumentError, TypeError
      nil
    end

    def generate_same_currency_rates(from, to, start_date, end_date)
      (start_date..end_date).map { |date| Rate.new(date: date, from: from, to: to, rate: 1.0) }
    end

    def client
      @client ||= Faraday.new do |f|
        f.request :json
        f.response :raise_error
        f.headers["Accept"] = "application/json"
        f.options.timeout = 10
        f.options.open_timeout = 5
      end
    end
end
