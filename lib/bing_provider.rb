# frozen_string_literal: true

require_relative 'provider'

# Bing Translator, talked to through the endpoint its web UI uses.
#
# Ported from upstream's dialect/providers/modules/bing.py.
#
# Upstream reads the language list and the IID out of the page with
# BeautifulSoup, and the abuse-prevention key, token and IG with regular
# expressions. The port has no HTML parser available, so all five are scraped
# with expressions anchored on the same attributes BeautifulSoup selects on.
# Bing serves the page with unquoted attribute values (`id=t_tgtAllLang`),
# which an HTML parser normalizes away and an expression has to allow for.
class BingProvider < Provider
  HEADERS = {
    'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    'Accept'     => '*/*',
  }.freeze

  # The optgroup BeautifulSoup looks up by id, and the options inside it.
  LANGS_GROUP_PATTERN = /<optgroup[^>]*\bid=["']?t_tgtAllLang["']?[^>]*>(.*?)<\/optgroup>/m
  LANG_OPTION_PATTERN = /<option[^>]*\bvalue=["']?([^"'\s>]+)["']?[^>]*>([^<]*)</m

  # The tag BeautifulSoup looks up by id, for its data-iid attribute. Only the
  # tag carries data-iid; the id also appears in the page's CSS, so the
  # expression requires both on the same tag.
  IID_PATTERN = /<[a-z]+[^>]*\bid=["']?rich_tta["']?[^>]*\bdata-iid=["']?([^"'\s>]+)["']?[^>]*>/mi

  ABUSE_PARAMS_PATTERN = /var params_AbusePreventionHelper = \[(.*?)\];/
  IG_PATTERN = /IG:"(.*?)",/

  def self.provider_name = 'bing'
  def self.prettyname = 'Bing'

  def self.capabilities = ProviderCapability::TRANSLATION
  def self.features = ProviderFeature::DETECTION | ProviderFeature::PRONUNCIATION

  DEFAULTS = {
    instance_url: '',
    api_key:      '',
    src_langs:    %w[en fr es de],
    dest_langs:   %w[fr es de en],
  }.freeze

  def self.defaults = DEFAULTS

  def initialize(**kwargs)
    super

    @chars_limit = 1000 # Web UI limit

    # Session vars
    @key = ''
    @token = ''
    @ig = ''
    @iid = ''
    @count = 1
  end

  def html_url = format_url('www.bing.com', '/translator')

  def translate_url
    format_url(
      'www.bing.com',
      '/ttranslatev3',
      { 'isVertical' => '1', '' => '', 'IG' => @ig, 'IID' => "#{@iid}.#{@count}" },
    )
  end

  def init_trans
    get(html_url, headers: HEADERS, check_common: false, return_json: false).then do |response|
      if response.to_s.empty?
        raise UnexpectedError, 'Could not get HTML from bing.com'
      end

      scrape(response)
    end
  end

  def translate(request)
    denormalize_lang(request.src, request.dest).then do |src, dest|
      # Increment requests count
      @count += 1

      post(translate_url, data: translate_data(request.text, src, dest), headers: HEADERS, form: true)
        .then { |response| translation_from(response, request) }
    end
  end

  def check_known_errors(status, data)
    if data.nil? || data == {} || data == ''
      raise UnexpectedError, "Response is empty! (HTTP #{status})"
    end

    if data.is_a?(Hash) && data.key?('errorMessage')
      raise ProviderError, data['errorMessage']
    end
  end

  private

    def scrape(html)
      add_scraped_langs(html)
      @iid = scrape_one(html, IID_PATTERN)
      scrape_abuse_params(html)
      @ig = scrape_one(html, IG_PATTERN)
    rescue UnexpectedError
      raise
    rescue StandardError => exc
      raise UnexpectedError, "Failed parsing HTML from bing.com: #{exc.message}"
    end

    def add_scraped_langs(html)
      html.match(LANGS_GROUP_PATTERN).then do |group|
        if group.nil?
          raise UnexpectedError, 'Failed parsing HTML from bing.com'
        end

        group[1].scan(LANG_OPTION_PATTERN).each { |code, name| add_lang(code, name.strip) }
      end
    end

    # The abuse-prevention array holds the key and the token, in that order.
    def scrape_abuse_params(html)
      scrape_one(html, ABUSE_PARAMS_PATTERN).delete('"').split(',').then do |abuse_params|
        @key = abuse_params[0]
        @token = abuse_params[1]
      end
    end

    def scrape_one(text, pattern)
      text.match(pattern).then do |match|
        if match.nil?
          raise UnexpectedError, 'Failed parsing HTML from bing.com'
        end

        match[1]
      end
    end

    def translate_data(text, src, dest)
      {
        'fromLang' => from_lang(src),
        'text'     => text,
        'to'       => dest,
        'token'    => @token,
        'key'      => @key,
      }
    end

    def from_lang(src)
      if src == 'auto'
        'auto-detect'
      else
        src
      end
    end

    def translation_from(response, request)
      response.first.then do |data|
        unless data.is_a?(Hash) && data.key?('translations')
          raise UnexpectedError, 'Unexpected translation response'
        end

        data['translations'].first.then do |translation|
          Translation.new(
            text:          translation.fetch('text'),
            original:      request,
            detected:      data.dig('detectedLanguage', 'language'),
            pronunciation: TranslationPronunciation.new(dest: translation.dig('transliteration', 'text')),
          )
        end
      end
    rescue UnexpectedError
      raise
    rescue StandardError => exc
      raise UnexpectedError, exc.message
    end
end
