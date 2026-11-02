# frozen_string_literal: true

require 'tempfile'
require 'uri'

require_relative 'provider'

# Lingva Translate, a Google Translate front end.
#
# Ported from upstream's dialect/providers/modules/lingva.py.
class LingvaProvider < Provider
  def self.provider_name = 'lingva'
  def self.prettyname = 'Lingva Translate'

  def self.capabilities = ProviderCapability::TRANSLATION | ProviderCapability::TTS

  def self.features
    ProviderFeature::INSTANCES |
      ProviderFeature::DETECTION |
      ProviderFeature::MISTAKES |
      ProviderFeature::PRONUNCIATION
  end

  DEFAULTS = {
    instance_url: 'lingva.dialectapp.org',
    api_key:      '',
    src_langs:    %w[en fr es de],
    dest_langs:   %w[fr es de en],
  }.freeze

  def self.defaults = DEFAULTS

  def initialize(**kwargs)
    super

    @chars_limit = 5000
  end

  def lang_url = format_url(instance_url, '/api/v1/languages/')

  def validate_instance(url)
    get(format_url(url, '/api/v1/en/es/hello'), check_common: false).then do |response|
      response.is_a?(Hash) && response.key?('translation')
    end
  rescue RequestError, ProviderError, JSON::ParserError
    false
  end

  # Lingva serves its language list from one endpoint for both capabilities,
  # so upstream initializes either from the same call.
  def init
    get(lang_url).then do |response|
      if response.is_a?(Hash) && response.key?('languages')
        response['languages'].each do |lang|
          unless lang['code'] == 'auto'
            add_lang(lang['code'], lang['name'], tts: true)
          end
        end
      else
        raise UnexpectedError, 'No langs found in server.'
      end
    end
  end

  def init_trans = init
  def init_tts = init

  def translate(request)
    denormalize_lang(request.src, request.dest).then do |src, dest|
      get(translate_url(request.text, src, dest)).then do |response|
        translation_from(response, request)
      end
    end
  end

  def speech(text, language)
    denormalize_lang(language).then do |(lang)|
      get(speech_url(text, lang)).then do |response|
        audio_file(response)
      end
    end
  end

  # Raises the matching error when the service reported one.
  def check_known_errors(status, data)
    if data.nil? || data == {} || data == ''
      raise UnexpectedError, "Response is empty! (HTTP #{status})"
    end

    if data.is_a?(Hash) && data.key?('error')
      raise_lingva_error(data['error'])
    end
  end

  private

    def translate_url(text, src, dest)
      format_url(instance_url, "/api/v1/#{src}/#{dest}/#{URI.encode_www_form_component(text).gsub('+', '%20')}")
    end

    def speech_url(text, lang)
      format_url(instance_url, "/api/v1/audio/#{lang}/#{URI.encode_www_form_component(text).gsub('+', '%20')}")
    end

    def translation_from(response, request)
      response.fetch('info', {}).then do |info|
        info.fetch('pronunciation', {}).then do |pronunciation|
          info['typo'].then do |mistakes|
            Translation.new(
              text:          response.fetch('translation'),
              original:      request,
              detected:      info['detectedSource'],
              mistakes:      mistake_for(mistakes),
              pronunciation: TranslationPronunciation.new(
                src:  pronunciation['query'],
                dest: pronunciation['translation'],
              ),
            )
          end
        end
      end
    rescue KeyError, NoMethodError, TypeError => exc
      raise UnexpectedError, "Failed reading the translation data: #{exc.message}"
    end

    # Lingva reports a typo as plain text, which upstream uses for both the
    # markup and the text of the mistake.
    def mistake_for(mistakes)
      if mistakes.nil? || mistakes.empty?
        nil
      else
        TranslationMistake.new(markup: mistakes, text: mistakes)
      end
    end

    # Lingva returns the audio as a JSON array of byte values.
    def audio_file(response)
      Tempfile.new(['dialect-speech', '.mp3'], binmode: true).tap do |file|
        file.write(response.fetch('audio').pack('C*'))
        file.rewind
      end
    rescue KeyError, TypeError, RangeError => exc
      raise UnexpectedError, "Failed reading the speech audio: #{exc.message}"
    end

    def raise_lingva_error(error)
      case error
      when 'Invalid target language', 'Invalid source language'
        raise InvalidLangCode, error
      else
        raise UnexpectedError, error
      end
    end
end
