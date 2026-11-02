# frozen_string_literal: true

require_relative 'provider'

# LibreTranslate, the self-hostable machine translation API.
#
# Ported from upstream's dialect/providers/modules/libretrans.py.
class LibretranslateProvider < Provider
  def self.provider_name = 'libretranslate'
  def self.prettyname = 'LibreTranslate'

  def self.capabilities = ProviderCapability::TRANSLATION
  def self.features = ProviderFeature::INSTANCES | ProviderFeature::DETECTION

  DEFAULTS = {
    instance_url: 'lt.dialectapp.org',
    api_key:      '',
    src_langs:    %w[en fr es de],
    dest_langs:   %w[fr es de en],
  }.freeze

  def self.defaults = DEFAULTS

  def initialize(**kwargs)
    super

    @chars_limit = 0
  end

  def frontend_settings_url = format_url(instance_url, '/frontend/settings')
  def detect_url = format_url(instance_url, '/detect')
  def lang_url = format_url(instance_url, '/languages')
  def suggest_url = format_url(instance_url, '/suggest')
  def translate_url = format_url(instance_url, '/translate')

  def validate_instance(url)
    get(format_url(url, '/spec'), check_common: false).then do |response|
      response.dig('info', 'title') == 'LibreTranslate'
    end
  rescue RequestError, ProviderError, JSON::ParserError, TypeError
    false
  end

  def validate_api_key(key)
    post(detect_url, data: { 'q' => 'hello', 'api_key' => key }, form: true).then do |response|
      response.is_a?(Array) && response.first.is_a?(Hash) && response.first.key?('confidence')
    end
  rescue APIKeyInvalid, APIKeyRequired
    false
  end

  # Reads the instance's languages and its frontend settings, which is where
  # LibreTranslate says whether it takes suggestions and API keys.
  def init_trans
    get(lang_url).then do |languages|
      get(frontend_settings_url).then do |settings|
        languages.each { |lang| add_lang(lang['code'], lang['name']) }
        apply_frontend_settings(settings)
      end
    end
  rescue RequestError, ProviderError
    raise
  rescue StandardError => exc
    raise UnexpectedError, exc.message
  end

  def translate(request)
    denormalize_lang(request.src, request.dest).then do |src, dest|
      post(translate_url, data: with_api_key('q' => request.text, 'source' => src, 'target' => dest))
        .then { |response| translation_from(response, request) }
    end
  end

  def suggest(text, src, dest, suggestion)
    denormalize_lang(src, dest).then do |real_src, real_dest|
      with_api_key('q' => text, 'source' => real_src, 'target' => real_dest, 's' => suggestion).then do |data|
        post(suggest_url, data: data, form: true).then do |response|
          response.is_a?(Hash) && response.fetch('success', false)
        end
      end
    end
  end

  def check_known_errors(status, data)
    if data.nil? || data == {} || data == ''
      raise UnexpectedError, "Response is empty! (HTTP #{status})"
    end

    if data.is_a?(Hash) && data.key?('error')
      raise_libretranslate_error(data['error'])
    end
  end

  private

    # LibreTranslate takes the API key alongside the request data, but only
    # when the instance said it accepts keys at all.
    def with_api_key(data)
      data.dup.tap do |body|
        if !api_key.empty? && feature?(ProviderFeature::API_KEY)
          body['api_key'] = api_key
        end
      end
    end

    def apply_frontend_settings(settings)
      if settings.fetch('suggestions', false)
        add_feature(ProviderFeature::SUGGESTIONS)
      end

      if settings.fetch('apiKeys', false)
        add_feature(ProviderFeature::API_KEY)
      end

      if settings.fetch('keyRequired', false)
        add_feature(ProviderFeature::API_KEY_REQUIRED)
      end

      @chars_limit = settings.fetch('charLimit', 0).to_i
    end

    def translation_from(response, request)
      Translation.new(
        text:     response.fetch('translatedText'),
        original: request,
        detected: response.dig('detectedLanguage', 'language'),
      )
    rescue KeyError, TypeError => exc
      raise UnexpectedError, exc.message
    end

    def raise_libretranslate_error(error)
      case error
      when 'Please contact the server operator to obtain an API key'
        raise APIKeyRequired, error
      when 'Invalid API key'
        raise APIKeyInvalid, error
      when /is not supported/
        raise InvalidLangCode, error
      when /exceeds text limit/
        raise BatchSizeExceeded, error
      when /exceeds character limit/
        raise CharactersLimitExceeded, error
      else
        raise UnexpectedError, error
      end
    end
end
