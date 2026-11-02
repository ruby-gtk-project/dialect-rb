# frozen_string_literal: true

require_relative 'provider'

# DeepL's translation API.
#
# Ported from upstream's dialect/providers/modules/deepl.py.
class DeeplProvider < Provider
  API_V = 'v2'

  API_FREE = 'api-free.deepl.com'
  API_PRO = 'api.deepl.com'

  # DeepL API Free keys can be identified by this suffix.
  FREE_KEY_SUFFIX = ':fx'

  def self.provider_name = 'deepl'
  def self.prettyname = 'DeepL'

  def self.capabilities = ProviderCapability::TRANSLATION

  def self.features
    ProviderFeature::DETECTION |
      ProviderFeature::API_KEY |
      ProviderFeature::API_KEY_REQUIRED |
      ProviderFeature::API_KEY_USAGE
  end

  def self.lang_comp = ProviderLangComparison::DEEP

  DEFAULTS = {
    instance_url: '',
    api_key:      '',
    src_langs:    %w[en fr es de],
    dest_langs:   %w[fr es de en-US],
  }.freeze

  def self.defaults = DEFAULTS

  def initialize(**kwargs)
    super

    @chars_limit = 5000
    @api_url = self.class.api_url_for(api_key)
  end

  attr_reader :api_url

  # DeepL serves Free and Pro keys from different hosts.
  def self.api_url_for(api_key)
    if api_key.to_s.end_with?(FREE_KEY_SUFFIX)
      API_FREE
    else
      API_PRO
    end
  end

  # Retried automatically: DeepL rate-limits with 429.
  def retry_errors = [429]

  def source_lang_url = format_url(api_url, "/#{API_V}/languages", { 'type' => 'source' })
  def target_lang_url = format_url(api_url, "/#{API_V}/languages", { 'type' => 'target' })
  def translate_url = format_url(api_url, "/#{API_V}/translate")
  def usage_url = format_url(api_url, "/#{API_V}/usage")

  def headers = { 'Authorization' => "DeepL-Auth-Key #{api_key}" }

  # Upstream loops over `src_langs` twice here, so its destination list is
  # really a copy of the source one; the second loop reads the target-language
  # response, which is what the two separate requests are for.
  def init_trans
    get(source_lang_url, headers: headers).then do |src_langs|
      get(target_lang_url, headers: headers).then do |dest_langs|
        if src_langs.is_a?(Array) && dest_langs.is_a?(Array) && !src_langs.empty? && !dest_langs.empty?
          src_langs.each { |lang| add_lang(lang['language'], lang['name'], trans_dest: false) }
          dest_langs.each { |lang| add_lang(lang['language'], lang['name'], trans_src: false) }
        end
      end
    end
  end

  def validate_api_key(key)
    self.class.api_url_for(key).then do |url|
      get(
        format_url(url, "/#{API_V}/languages", { 'type' => 'source' }),
        headers: { 'Authorization' => "DeepL-Auth-Key #{key}" },
      )

      true
    end
  rescue APIKeyInvalid, APIKeyRequired
    false
  end

  def translate(request)
    denormalize_lang(request.src, request.dest).then do |src, dest|
      post(translate_url, data: translate_data(request.text, src, dest), headers: headers).then do |response|
        translation_from(response, request)
      end
    end
  end

  def api_char_usage
    get(usage_url, headers: headers).then do |response|
      [response.fetch('character_count'), response.fetch('character_limit')]
    end
  rescue KeyError, TypeError => exc
    raise UnexpectedError, exc.message
  end

  def check_known_errors(status, data)
    message_of(data).then do |message|
      case status
      when 403
        if api_key.empty?
          raise APIKeyRequired, message
        end

        raise APIKeyInvalid, message
      when 456 then raise ServiceLimitReached, message
      when 429 then raise UnexpectedError, 'Too many requests!'
      end

      unless status == 200
        raise UnexpectedError, message
      end

      if data.nil? || data == {} || data == ''
        raise UnexpectedError, "Response is empty! (HTTP #{status})"
      end
    end
  end

  private

    def translate_data(text, src, dest)
      { 'text' => [text], 'target_lang' => dest }.tap do |data|
        unless src == 'auto'
          data['source_lang'] = src
        end
      end
    end

    def translation_from(response, request)
      if response.is_a?(Hash)
        response['translations']
      end.then do |translations|
        if translations.nil? || translations.empty?
          raise UnexpectedError, 'Failed reading the translation data'
        end

        Translation.new(
          text:     translations.first.fetch('text'),
          original: request,
          detected: translations.first['detected_source_language'],
        )
      end
    end

    def message_of(data)
      if data.is_a?(Hash)
        data.fetch('message', '').to_s
      else
        ''
      end
    end
end
