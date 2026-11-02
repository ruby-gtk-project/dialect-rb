# frozen_string_literal: true

require 'json'
require 'securerandom'

require_relative 'provider'

# Yandex Translate, talked to through the endpoint its Android app uses.
#
# Ported from upstream's dialect/providers/modules/yandex.py.
class YandexProvider < Provider
  HEADERS = {
    'User-Agent' => 'ru.yandex.translate/21.15.4.21402814 (Xiaomi Redmi K20 Pro; Android 11)',
  }.freeze

  def self.provider_name = 'yandex'
  def self.prettyname = 'Yandex'

  def self.capabilities = ProviderCapability::TRANSLATION
  def self.features = ProviderFeature::DETECTION
  def self.lang_comp = ProviderLangComparison::DEEP

  DEFAULTS = {
    instance_url: '',
    api_key:      '',
    src_langs:    %w[en fr es de],
    dest_langs:   %w[fr es de en],
  }.freeze

  def self.defaults = DEFAULTS

  OPENING_BRACKETS = ['{', '['].freeze
  CLOSING_BRACKETS = ['}', ']'].freeze

  def initialize(**kwargs)
    super

    @chars_limit = 10_000
    @uuid = SecureRandom.uuid.delete('-')
  end

  def translate_url
    format_url(
      'translate.yandex.net',
      '/api/v1/tr.json/translate',
      { 'id' => "#{@uuid}-0-0", 'srv' => 'android' },
    )
  end

  # Scrapes the web front end for the language list: /api/v1/tr.json/getLangs
  # does not report every language Yandex supports.
  #
  # Upstream pulls the two JavaScript literals out of the HTML with
  # expressions anchored on a bare `TRANSLATOR_LANGS: ...,` assignment and a
  # trailing newline. The page now embeds the same two keys inside one JSON
  # blob as `"TRANSLATOR_LANGS":{...}`, with no newline to stop at, so the
  # port finds the key either way and then reads the literal that follows by
  # balancing its brackets.
  def init_trans
    get(format_url('translate.yandex.com'), check_common: false, return_json: false).then do |response|
      if response.to_s.empty?
        raise UnexpectedError, 'Could not get HTML from yandex.com'
      end

      add_scraped_langs(response)
    end
  end

  def translate(request)
    denormalize_lang(request.src, request.dest).then do |src, dest|
      post(translate_url, data: translate_data(request.text, src, dest), headers: HEADERS, form: true)
        .then { |response| translation_from(response, request) }
    end
  end

  private

    def add_scraped_langs(html)
      scrape_json(html, 'TRANSLATOR_LANGS').then do |languages|
        # Dialects are not valid source translation langs.
        scrape_json(html, 'DIALECTS').then do |dialects|
          languages.each do |code, name|
            add_lang(code, name, trans_src: !dialects.include?(code))
          end
        end
      end
    rescue UnexpectedError
      raise
    rescue StandardError => exc
      raise UnexpectedError, "Failed parsing HTML from yandex.com: #{exc.message}"
    end

    def scrape_json(html, key)
      html.match(/["']?#{Regexp.escape(key)}["']?\s*:\s*/).then do |match|
        if match.nil?
          raise UnexpectedError, 'Failed parsing HTML from yandex.com'
        end

        JSON.parse(literal_at(html, match.end(0)))
      end
    end

    # The JSON object or array starting at +offset+, found by balancing
    # brackets while ignoring anything inside a string.
    def literal_at(html, offset)
      scan_literal(html, offset).then do |length|
        if length.zero?
          raise UnexpectedError, 'Failed parsing HTML from yandex.com'
        end

        html[offset, length]
      end
    end

    # Walks forward from the literal's opening bracket and answers its length
    # once the brackets balance, or zero when they never do.
    def scan_literal(html, offset)
      depth = 0
      length = 0
      in_string = false
      escaped = false
      index = offset

      while index < html.length && length.zero?
        char = html[index]

        if escaped
          escaped = false
        elsif in_string
          if char == '\\'
            escaped = true
          elsif char == '"'
            in_string = false
          end
        elsif char == '"'
          in_string = true
        elsif OPENING_BRACKETS.include?(char)
          depth += 1
        elsif CLOSING_BRACKETS.include?(char)
          depth -= 1

          if depth.zero?
            length = index - offset + 1
          end
        end

        index += 1
      end

      length
    end

    def translate_data(text, src, dest)
      { 'text' => text }.tap do |data|
        if src == 'auto'
          data['lang'] = dest
        else
          data['lang'] = "#{src}-#{dest}"
        end
      end
    end

    def error_message_of(response)
      if response.is_a?(Hash)
        response.fetch('message', '')
      else
        ''
      end
    end

    def translation_from(response, request)
      unless response.is_a?(Hash) && response['code'] == 200
        raise ProviderError, error_message_of(response)
      end

      Translation.new(
        text:     response.fetch('text').first,
        original: request,
        detected: response['lang'].then { |lang| lang && lang.split('-').first },
      )
    rescue ProviderError
      raise
    rescue StandardError => exc
      raise UnexpectedError, exc.message
    end
end
