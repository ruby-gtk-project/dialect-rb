# frozen_string_literal: true

require_relative 'provider'

# Kagi Translate, which authenticates with a Kagi session token.
#
# Ported from upstream's dialect/providers/modules/kagi.py.
class KagiProvider < Provider
  API_URL = 'translate.kagi.com/api'

  def self.provider_name = 'kagi'
  def self.prettyname = 'Kagi Translate'

  def self.capabilities = ProviderCapability::TRANSLATION

  def self.features
    ProviderFeature::DETECTION | ProviderFeature::API_KEY | ProviderFeature::API_KEY_REQUIRED
  end

  def self.lang_comp = ProviderLangComparison::DEEP

  DEFAULTS = {
    instance_url: '',
    api_key:      '',
    src_langs:    %w[en fr es de ja zh],
    dest_langs:   %w[fr es de en ja zh],
  }.freeze

  def self.defaults = DEFAULTS

  def initialize(**kwargs)
    super

    @api_url = API_URL
    @chars_limit = 20_000 # Web UI limit
  end

  attr_reader :api_url

  def headers = { 'Content-Type' => 'application/json' }

  def lang_url = format_url(api_url, '/list-languages', { 'token' => api_key })
  def translate_url = format_url(api_url, '/translate', { 'token' => api_key })

  # Tests the session token by asking Kagi whether it is logged in.
  def validate_api_key(key)
    get(format_url(api_url, '/auth', { 'token' => key }), headers: headers).then do |response|
      response.is_a?(Hash) && response['loggedIn'] == true
    end
  rescue APIKeyRequired, UnexpectedError
    false
  end

  def init_trans
    get(lang_url, headers: headers).then do |languages|
      if languages.is_a?(Array) && !languages.empty?
        # Kagi returns upper-case codes, which upstream lower-cases before
        # normalization.
        languages.each { |lang| add_lang(lang['language'].downcase, lang['name']) }
      end
    end
  end

  def translate(request)
    denormalize_lang(request.src, request.dest).then do |src, dest|
      post(translate_url, data: translate_data(request.text, src, dest), headers: headers).then do |response|
        translation_from(response, request)
      end
    end
  end

  def check_known_errors(status, data)
    if data.nil? || data == {} || data == ''
      raise UnexpectedError, 'Response is empty'
    end

    if data.is_a?(Hash) && data.key?('error')
      raise_kagi_error(data['error'])
    end

    case status
    when 401 then raise APIKeyRequired, 'Unauthorized - invalid session token'
    when 403 then raise APIKeyRequired, 'Forbidden - session token required'
    else
      unless status == 200
        raise UnexpectedError, "HTTP #{status} error"
      end
    end
  end

  private

    def translate_data(text, src, dest)
      {
        'text'            => text,
        'source_lang'     => src,
        'target_lang'     => dest,
        'skip_definition' => true, # Get translation only, no definitions
      }
    end

    def translation_from(response, request)
      unless response.is_a?(Hash)
        raise UnexpectedError, 'Failed reading the translation data'
      end

      Translation.new(
        text:     response.fetch('translation'),
        original: request,
        detected: response['detected_language'].then { |detected| detected && detected['iso'] },
      )
    rescue KeyError => exc
      raise UnexpectedError, "Failed reading the translation data: #{exc.message}"
    end

    # A token problem reads as an API key problem to the window, which then
    # offers to remove the key and retry.
    def raise_kagi_error(error)
      if %w[token unauthorized authentication].any? { |keyword| error.to_s.downcase.include?(keyword) }
        raise APIKeyRequired, "Invalid session token: #{error}"
      end

      raise UnexpectedError, error
    end
end
