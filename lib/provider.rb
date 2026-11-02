# frozen_string_literal: true

require 'uri'

require_relative 'define'
require_relative 'languages'
require_relative 'provider_errors'
require_relative 'provider_settings'
require_relative 'session'

# What a provider can do.
#
# Ported from upstream's ProviderCapability. Upstream uses Python's Flag
# enums; the port keeps plain bit flags so `|` composition and membership
# tests read the same way.
module ProviderCapability
  TRANSLATION = 1 << 0
  TTS         = 1 << 1
  DEFINITIONS = 1 << 2
end

# Optional behaviours a provider may support.
#
# Ported from upstream's ProviderFeature.
module ProviderFeature
  NONE             = 0
  INSTANCES        = 1 << 1
  API_KEY          = 1 << 2
  API_KEY_REQUIRED = 1 << 3
  API_KEY_USAGE    = 1 << 4
  DETECTION        = 1 << 5
  MISTAKES         = 1 << 6
  PRONUNCIATION    = 1 << 7
  SUGGESTIONS      = 1 << 8
end

# How a provider's language lists are built.
#
# Ported from upstream's ProviderLangModel. STATIC providers populate both
# src_languages and dest_languages and compare codes with #cmp_langs; DYNAMIC
# providers populate only src_languages and answer #dest_langs_for.
module ProviderLangModel
  STATIC = :static
  DYNAMIC = :dynamic
end

# How #cmp_langs compares two codes.
#
# Ported from upstream's ProviderLangComparison. PLAIN compares codes whole;
# DEEP also counts a match on the base code, ignoring an ISO 3166-1 country or
# ISO 15924 script suffix.
module ProviderLangComparison
  PLAIN = :plain
  DEEP = :deep
end

# A translation to perform.
#
# Ported from upstream's TranslationRequest.
TranslationRequest = Data.define(:text, :src, :dest)

# A spelling mistake a service found in the source text, as Pango markup and
# as plain text.
#
# Ported from upstream's TranslationMistake.
TranslationMistake = Data.define(:markup, :text)

# Pronunciations of the source and translated text, either of which a service
# may leave out.
#
# Ported from upstream's TranslationPronunciation.
TranslationPronunciation = Data.define(:src, :dest) do
  def initialize(src: nil, dest: nil) = super
end

# A finished translation.
#
# Ported from upstream's Translation.
Translation = Data.define(
  :text,
  :original,
  :detected,
  :mistakes,
  :pronunciation,
) do
  def initialize(text:, original:, detected: nil, mistakes: nil, pronunciation: TranslationPronunciation.new)
    super
  end
end

# The base class every provider subclasses.
#
# Ported from upstream's dialect/providers/base.py, with the HTTP helpers of
# dialect/providers/soup.py mixed in from session.rb.
#
# Upstream also has a LocalProvider base (dialect/providers/local.py) whose
# only job is `run_async`, pushing blocking work into a ThreadPoolExecutor so
# it can be awaited from the GLib loop. The port has no need for it: provider
# methods here are plain blocking calls, and it is BackgroundTask that moves
# them off the main thread, so a provider that does local work just does it.
#
# Upstream declares the provider's identity as class attributes named `name`
# and `defaults`. `name` is taken on a Ruby class, so the port spells it
# `provider_name`; subclasses override these class methods.
class Provider
  include SessionHelpers

  DEFAULTS = {
    instance_url: '',
    api_key:      '',
    src_langs:    %w[en fr es de],
    dest_langs:   %w[fr es de en],
  }.freeze

  # Module name for code use, such as settings storing.
  def self.provider_name = ''

  # Module name for UI display.
  def self.prettyname = ''

  # Provider capabilities: translation, TTS, etc.
  def self.capabilities = 0

  # Provider features.
  def self.features = ProviderFeature::NONE

  # Translation language model.
  def self.lang_model = ProviderLangModel::STATIC

  # Behaviour of the default #cmp_langs.
  def self.lang_comp = ProviderLangComparison::PLAIN

  # Default provider settings.
  def self.defaults = DEFAULTS

  # Source languages available for translating.
  attr_reader :src_languages

  # Destination languages available for translating.
  attr_reader :dest_languages

  # Languages available for TTS.
  attr_reader :tts_languages

  # Translation char limit, -1 when the provider imposes none.
  attr_accessor :chars_limit

  # The translation history.
  attr_reader :history

  # The provider's features, which a provider may widen once it has talked to
  # its service, as LibreTranslate does with its frontend settings.
  attr_accessor :features

  attr_reader :settings

  def initialize(settings: nil)
    @src_languages = []
    @dest_languages = []
    @tts_languages = []
    @nonstandard_langs = {}
    @languages_names = {}
    @chars_limit = -1
    @history = []
    @features = self.class.features
    @settings = settings || ProviderSettings.new(provider_name, self.class.defaults)
  end

  def provider_name = self.class.provider_name
  def prettyname = self.class.prettyname
  def capabilities = self.class.capabilities
  def lang_model = self.class.lang_model
  def lang_comp = self.class.lang_comp

  # --- Providers API methods ---

  # Validates an instance of the provider, given only its hostname and tld,
  # e.g. "libretranslate.com" or "localhost".
  def validate_instance(url)
    raise NotImplementedError, "#{provider_name} has no instances to validate (#{url})"
  end

  # Validates an API key.
  def validate_api_key(key)
    raise NotImplementedError, "#{provider_name} takes no API key (#{key.class})"
  end

  # Initializes the provider's translation capabilities.
  def init_trans
    raise NotImplementedError, "#{provider_name} does not translate"
  end

  # Initializes the provider's text-to-speech capabilities.
  def init_tts
    raise NotImplementedError, "#{provider_name} does not speak"
  end

  # Translates text. Providers are handed normalized lang codes and are
  # expected to run them through #denormalize_lang.
  def translate(request)
    raise NotImplementedError, "#{provider_name} does not translate (#{request.class})"
  end

  # Sends a translation suggestion to the provider.
  def suggest(text, src, dest, suggestion)
    raise NotImplementedError,
      "#{provider_name} takes no suggestions (#{text.class}, #{src}, #{dest}, #{suggestion.class})"
  end

  # Generates speech audio from text, returning the bytes of an audio file.
  def speech(text, language)
    raise NotImplementedError, "#{provider_name} does not speak (#{text.class}, #{language})"
  end

  # The API usage status, as [usage, limit].
  def api_char_usage
    raise NotImplementedError, "#{provider_name} reports no API usage"
  end

  # Compares two language codes, which are assumed to have been normalized by
  # #normalize_lang_code. Providers override this to add their own logic.
  def cmp_langs(first, second)
    if first == second
      true
    elsif lang_comp == ProviderLangComparison::PLAIN
      false
    else
      first.split('-').first == second.split('-').first
    end
  end

  # The available destination languages for a source language, for DYNAMIC
  # providers.
  def dest_langs_for(code)
    raise NotImplementedError, "#{provider_name} has a static language model (#{code})"
  end

  # Mapping of Dialect/CLDR lang codes to the provider's own, for providers
  # whose codes diverge. See Define::LANG_ALIASES for reference mappings.
  def lang_aliases = {}

  # --- Provider features helpers ---

  def supports_instances? = feature?(ProviderFeature::INSTANCES)
  def supports_api_key? = feature?(ProviderFeature::API_KEY)
  def api_key_required? = feature?(ProviderFeature::API_KEY_REQUIRED)
  def supports_api_usage? = feature?(ProviderFeature::API_KEY_USAGE)
  def supports_detection? = feature?(ProviderFeature::DETECTION)
  def supports_mistakes? = feature?(ProviderFeature::MISTAKES)
  def supports_pronunciation? = feature?(ProviderFeature::PRONUNCIATION)
  def supports_suggestions? = feature?(ProviderFeature::SUGGESTIONS)

  def feature?(feature) = features & feature != 0

  # Turns a feature on, as LibreTranslate does once its instance has told it
  # what it supports. Upstream writes `self.features ^= FEATURE`, which only
  # happens to add because the flag is known to be unset.
  def add_feature(feature)
    self.features = features | feature
  end

  def capability?(capability) = capabilities & capability != 0
  def translates? = capability?(ProviderCapability::TRANSLATION)
  def speaks? = capability?(ProviderCapability::TTS)
  def defines? = capability?(ProviderCapability::DEFINITIONS)

  # --- Provider settings helpers ---

  # Instance url saved in settings.
  def instance_url = settings.instance_url
  def instance_url=(url)
    settings.instance_url = url
  end

  # Resets the saved instance url.
  def reset_instance_url
    self.instance_url = ''
  end

  # API key saved in settings.
  def api_key = settings.api_key
  def api_key=(key)
    settings.api_key = key
  end

  # Resets the saved API key.
  def reset_api_key
    self.api_key = ''
  end

  # The user's recent source langs.
  def recent_src_langs = settings.src_langs
  def recent_src_langs=(src_langs)
    settings.src_langs = src_langs
  end

  def reset_src_langs
    self.recent_src_langs = []
  end

  # The user's recent destination langs.
  def recent_dest_langs = settings.dest_langs
  def recent_dest_langs=(dest_langs)
    settings.dest_langs = dest_langs
  end

  def reset_dest_langs
    self.recent_dest_langs = []
  end

  # --- General provider helpers ---

  # Composes an HTTP url out of a hostname, a path and query params.
  #
  # If +url+ is a localhost address, +http+ is ignored and HTTP is forced.
  def self.format_url(url, path = '', params = {}, http: false)
    path.to_s.then do |full_path|
      unless full_path.start_with?('/')
        full_path = "/#{full_path}"
      end

      "#{protocol_for(url, http)}#{url}#{full_path}#{query_for(params)}"
    end
  end

  def self.protocol_for(url, http)
    if url.start_with?('localhost:') || http
      'http://'
    else
      'https://'
    end
  end

  def self.query_for(params)
    URI.encode_www_form(params).then do |query|
      if query.empty?
        ''
      else
        "?#{query}"
      end
    end
  end

  def format_url(url, path = '', params = {}, http: false)
    self.class.format_url(
      url,
      path,
      params,
      http: http,
    )
  end

  # Normalizes a language code with Dialect's criteria, mapping it through
  # Define::LANG_ALIASES and the provider's own #lang_aliases.
  #
  # Criteria:
  #   - codes are lowercase, e.g. ES => es
  #   - a second code is delimited by a hyphen, e.g. zh_CN => zh-CN
  #   - a two-char second code is a country code and is uppercased,
  #     e.g. zh-cn => zh-CN
  #   - a four-char second code is a script code and is capitalized,
  #     e.g. zh-HANS => zh-Hans
  def normalize_lang_code(code)
    code.to_s.tr('_', '-').downcase.split('-').then do |codes|
      if codes.length == 2
        codes[1] = normalize_subtag(codes[1])
      end

      Define::LANG_ALIASES.merge(lang_aliases).then do |aliases|
        codes.join('-').then { |joined| aliases.fetch(joined, joined) }
      end
    end
  end

  # Registers a language the provider supports, normalizing its code and
  # remembering the original for later denormalization.
  def add_lang(original_code, name = nil, trans_src: true, trans_dest: true, tts: false)
    normalize_lang_code(original_code).then do |code|
      if trans_src
        src_languages << code
      end

      if trans_dest
        dest_languages << code
      end

      if tts
        tts_languages << code
      end

      remember_lang(code, original_code, name)
    end
  end

  # The provider's own codes for the given normalized codes.
  def denormalize_lang(*codes)
    codes.map { |code| @nonstandard_langs.fetch(code, code) }
  end

  # A localized language name, falling back to the name the provider gave us
  # and ultimately to the code itself.
  def get_lang_name(code)
    Languages.lang_name(code) || @languages_names.fetch(code, code)
  end

  private

    def normalize_subtag(subtag)
      case subtag.length
      when 4 then subtag.capitalize # ISO 15924 (script)
      when 2 then subtag.upcase     # ISO 3166-1 (country)
      else subtag
      end
    end

    def remember_lang(code, original_code, name)
      if code != original_code && !@nonstandard_langs.key?(code)
        @nonstandard_langs[code] = original_code
      end

      if !name.nil? && !@languages_names.key?(code)
        @languages_names[code] = name
      end
    end
end
