# frozen_string_literal: true

require 'fileutils'
require 'json'

# Per-provider settings: the instance URL, the recent language lists, and the
# API key.
#
# Ported from upstream's dialect/providers/settings.py.
#
# Upstream reads and writes the `app.drey.Dialect.translator` schema at the
# per-provider path /app/drey/Dialect/translators/<name>/, and keeps the API
# key in the login keyring through libsecret. The Ruby bindings ship no Secret
# bindings, so keys live in their own JSON file under XDG_DATA_HOME with
# owner-only permissions, away from the settings file that syncs between
# machines. Upstream's migration path is kept: a key still sitting in the
# settings section is moved into the secrets file and cleared from settings on
# first read.
#
# Settings is required lazily rather than at the top of this file: settings.rb
# requires providers.rb for its provider lookups, which requires provider.rb,
# which requires this file, and a top-level require would leave one of the
# three half-loaded depending on which was asked for first.
class ProviderSettings
  attr_reader :name, :defaults

  def initialize(name, defaults, settings: nil, secrets_path: nil)
    @name = name
    @defaults = defaults
    @settings = settings
    @secrets_path = secrets_path || self.class.default_secrets_path
    @api_key_observers = []
  end

  # The app settings these provider sections live in.
  def settings = @settings ||= default_settings

  def self.default_secrets_path
    File.join(
      ENV.fetch('XDG_DATA_HOME', File.expand_path('~/.local/share')),
      'dialect',
      'secrets.json',
    )
  end

  # Registers an observer for upstream's `changed::api-key` signal.
  def on_api_key_changed(&block)
    @api_key_observers << block
    block
  end

  # Whether the provider has been initialized at least once, the `init` key of
  # the translator schema.
  def init = section['init']

  def init=(state)
    settings.provider_set(name, 'init', state)
  end

  # The instance URL, falling back to the provider's own default.
  def instance_url
    section['instance-url'].then do |url|
      if url.empty?
        defaults[:instance_url]
      else
        url
      end
    end
  end

  def instance_url=(url)
    settings.provider_set(name, 'instance-url', url)
  end

  # The API key, read from the secrets file. A key left behind in the settings
  # section by an older release is migrated into the secrets file first.
  def api_key
    migrate_settings_api_key || secrets[name] || defaults[:api_key]
  end

  def api_key=(api_key)
    if api_key.to_s.empty?
      write_secrets(secrets.except(name))
    else
      write_secrets(secrets.merge(name => api_key))
    end

    notify_api_key_changed
    api_key
  end

  # Recent source languages.
  def src_langs
    section['src-langs'].then do |langs|
      if langs.empty?
        defaults[:src_langs]
      else
        langs
      end
    end
  end

  def src_langs=(src_langs)
    settings.provider_set(name, 'src-langs', src_langs)
  end

  # Recent destination languages.
  def dest_langs
    section['dest-langs'].then do |langs|
      if langs.empty?
        defaults[:dest_langs]
      else
        langs
      end
    end
  end

  def dest_langs=(dest_langs)
    settings.provider_set(name, 'dest-langs', dest_langs)
  end

  private

    def default_settings
      require_relative 'settings'
      Settings.get
    end

    def section = settings.provider_section(name)

    def notify_api_key_changed
      @api_key_observers.each { |observer| observer.call(name) }
    end

    # Moves a key still held in the settings section into the secrets file and
    # clears it from settings, returning it when there was one.
    def migrate_settings_api_key
      section['api-key'].then do |stored|
        unless stored.empty?
          write_secrets(secrets.merge(name => stored))
          settings.provider_set(name, 'api-key', '')
          stored
        end
      end
    end

    def secrets
      @secrets ||= JSON.parse(File.read(@secrets_path))
    rescue Errno::ENOENT, JSON::ParserError
      @secrets = {}
    end

    def write_secrets(values)
      @secrets = values
      FileUtils.mkdir_p(File.dirname(@secrets_path))
      File.write(@secrets_path, "#{JSON.pretty_generate(values)}\n")
      File.chmod(0o600, @secrets_path)
    end
end
