# frozen_string_literal: true

require 'fileutils'
require 'json'

require 'gtk4'

require_relative 'providers'

# Dialect's settings handler.
#
# Ported from upstream's dialect/settings.py, whose keys and defaults come
# from data/app.drey.Dialect.gschema.xml.in.
#
# Upstream subclasses Gio.Settings, which needs the compiled schema installed
# into the system's glib-2.0/schemas directory before the app will even start.
# Requiring an install step to run the port from a checkout is worse than the
# alternative, so the same keys, defaults and semantics are backed by a JSON
# file under XDG_CONFIG_HOME. The nesting mirrors the schema's children: the
# `tts` and `translators` sections are the two SettingsList children, and
# `providers` holds one `app.drey.Dialect.translator` section per provider,
# keyed by provider name where upstream keys by settings path.
#
# Upstream's `provider-changed` is a detailed GObject signal; GLib::Object
# subclasses in the Ruby bindings cannot declare their own signals without a
# full type registration, and Settings is not a widget, so observers register
# plain blocks through #on_provider_changed instead.
class Settings
  # Keys of the root `app.drey.Dialect` schema.
  DEFAULTS = {
    'window-size'              => [800, 300],
    'color-scheme'             => 'auto',
    'live-translation'         => false,
    'sp-translation'           => false,
    'show-pronunciation'       => false,
    'src-auto'                 => true,
    'translate-accel'          => 0,
    'custom-default-font-size' => false,
    'default-font-size'        => 0,
  }.freeze

  # Keys of the `app.drey.Dialect.SettingsList` children, with the `active`
  # override that both TranslatorsList and TTSList apply.
  LIST_DEFAULTS = {
    'list'   => [],
    'active' => 'google',
  }.freeze

  # Keys of the per-provider `app.drey.Dialect.translator` schema.
  PROVIDER_DEFAULTS = {
    'init'         => false,
    'src-langs'    => [],
    'dest-langs'   => [],
    'instance-url' => '',
    'api-key'      => '',
  }.freeze

  # Upstream maps the translate-accel enum to accelerators: 0 is Ctrl+Enter,
  # 1 is plain Enter, and anything else falls back to Ctrl+Enter.
  TRANSLATE_ACCELS = {
    0 => '<Primary>Return',
    1 => 'Return',
  }.freeze

  DEFAULT_TRANSLATE_ACCEL = '<Primary>Return'

  # The font size upstream falls back to when it cannot parse the system one.
  FALLBACK_FONT_SIZE = 11

  attr_reader :path

  def initialize(path: nil)
    @path = path || self.class.default_path
    @values = read
    @provider_observers = []
  end

  # The process-wide instance, matching upstream's Settings.get().
  def self.get = @instance ||= new

  # Drops the process-wide instance, so a test can point the next one at its
  # own file.
  def self.reset = @instance = nil

  def self.default_path
    File.join(
      ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config')),
      'dialect',
      'settings.json',
    )
  end

  def [](key) = @values.fetch(key.to_s) { DEFAULTS[key.to_s] }

  def []=(key, value)
    @values[key.to_s] = value
    write
    value
  end

  # Registers an observer for upstream's `provider-changed` signal. The block
  # is called with the kind that changed ("translator" or "tts") and the new
  # provider name.
  def on_provider_changed(&block)
    @provider_observers << block
    block
  end

  # --- Provider lists ---

  def translators_list = list_section('translators')['list']
  def translators_list=(translators)
    list_set('translators', 'list', translators)
  end

  # The active translator, with upstream's self-healing behaviour: a name that
  # no longer resolves to a loaded provider is replaced by the fallback.
  def active_translator
    list_section('translators')['active'].then do |value|
      if Providers.check_translator_availability(value)
        value
      else
        Providers.fallback_translator_name.tap { |name| self.active_translator = name }
      end
    end
  end

  def active_translator=(translator)
    list_set('translators', 'active', translator)
    notify_provider_changed('translator', translator)
    translator
  end

  # The active TTS provider, or "" for none. A name no longer backed by a
  # loaded provider is cleared, as upstream does.
  def active_tts
    list_section('tts')['active'].then do |value|
      if value.empty? || Providers::TTS.key?(value)
        value
      else
        ''.tap { |empty| self.active_tts = empty }
      end
    end
  end

  def active_tts=(tts)
    list_set('tts', 'active', tts)
    notify_provider_changed('tts', tts)
    tts
  end

  # --- Window and appearance ---

  def window_size = self['window-size'].first(2).map(&:to_i)
  def window_size=(size)
    self['window-size'] = size.to_a.first(2).map(&:to_i)
  end

  def color_scheme = self['color-scheme']
  def color_scheme=(scheme)
    self['color-scheme'] = scheme.to_s
  end

  # --- Translation behaviour ---

  def live_translation = self['live-translation']
  def live_translation=(state)
    self['live-translation'] = state
  end

  def sp_translation = self['sp-translation']
  def sp_translation=(state)
    self['sp-translation'] = state
  end

  def show_pronunciation = self['show-pronunciation']
  def show_pronunciation=(state)
    self['show-pronunciation'] = state
  end

  def src_auto = self['src-auto']
  def src_auto=(state)
    self['src-auto'] = state
  end

  # The user's preferred translation shortcut.
  def translate_accel = TRANSLATE_ACCELS.fetch(translate_accel_value, DEFAULT_TRANSLATE_ACCEL)

  def translate_accel_value = self['translate-accel'].to_i

  # --- Font size ---

  def custom_default_font_size = self['custom-default-font-size']
  def custom_default_font_size=(enabled)
    self['custom-default-font-size'] = enabled
  end

  def default_font_size = self['default-font-size'].to_i
  def default_font_size=(size)
    self['default-font-size'] = size.to_i
  end

  # The system's default font size, read off GTK's font name the way upstream
  # does, falling back to 11 when it cannot be parsed.
  def system_font_size
    Gtk::Settings.default.gtk_font_name.to_s.split.last.to_s.then do |size|
      if size.match?(/\A\d+\z/)
        size.to_i
      else
        FALLBACK_FONT_SIZE
      end
    end
  rescue StandardError
    FALLBACK_FONT_SIZE
  end

  # --- Per-provider sections, read and written by ProviderSettings ---

  def provider_section(provider) = PROVIDER_DEFAULTS.merge(providers.fetch(provider.to_s, {}))

  def provider_set(provider, key, value)
    providers[provider.to_s] = provider_section(provider).merge(key.to_s => value)
    write
    value
  end

  private

    def list_section(name) = LIST_DEFAULTS.merge(@values.fetch(name.to_s, {}))

    def list_set(name, key, value)
      @values[name.to_s] = list_section(name).merge(key.to_s => value)
      write
      value
    end

    def providers = @values['providers'] ||= {}

    def notify_provider_changed(kind, name)
      @provider_observers.each { |observer| observer.call(kind, name) }
    end

    def read
      JSON.parse(File.read(path)).then { |parsed| DEFAULTS.merge(parsed) }
    rescue Errno::ENOENT, JSON::ParserError
      DEFAULTS.dup
    end

    def write
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(@values)}\n")
    end
end
