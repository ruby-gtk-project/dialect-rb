# frozen_string_literal: true

require 'gtk4'

require_relative 'provider'
require_relative 'provider_errors'
require_relative 'bing_provider'
require_relative 'deepl_provider'
require_relative 'google_provider'
require_relative 'kagi_provider'
require_relative 'libretranslate_provider'
require_relative 'lingva_provider'
require_relative 'yandex_provider'

# The registry of provider classes and the list models the preferences
# dialog's dropdowns show.
#
# Ported from upstream's dialect/providers/__init__.py.
#
# Upstream discovers providers at import time by walking
# dialect.providers.modules with pkgutil and picking up each module's
# `Provider` class. Ruby has no equivalent of an importable package directory,
# and silently skipping a provider whose file failed to load is how a port
# ends up quietly missing a service, so the port requires each provider file
# above and registers the classes explicitly, in the alphabetical order
# pkgutil would have walked them.
module Providers
  # Every loaded provider, keyed by provider name.
  MODULES = {}

  # The loaded providers that can translate.
  TRANSLATORS = {}

  # The loaded providers that can speak.
  TTS = {}

  # The name shown for the "no provider" row of a dropdown.
  DISABLED_NAME = 'Disabled'

  module_function

  # Adds a provider class to the registry, under each capability it declares.
  def register(provider_class)
    MODULES[provider_class.provider_name] = provider_class

    if provider_class.capabilities & ProviderCapability::TRANSLATION != 0
      TRANSLATORS[provider_class.provider_name] = provider_class
    end

    if provider_class.capabilities & ProviderCapability::TTS != 0
      TTS[provider_class.provider_name] = provider_class
    end

    provider_class
  end

  def check_translator_availability(provider_name) = TRANSLATORS.key?(provider_name)

  def fallback_translator_name = TRANSLATORS.keys.first.to_s

  # The provider class registered under a name, or nil.
  def [](provider_name) = MODULES[provider_name]

  register(BingProvider)
  register(DeeplProvider)
  register(GoogleProvider)
  register(KagiProvider)
  register(LibretranslateProvider)
  register(LingvaProvider)
  register(YandexProvider)
end

# One provider in a list model. A ProviderObject with no class behind it is
# the "Disabled" row of the TTS dropdown.
#
# Ported from upstream's ProviderObject.
class ProviderObject < GLib::Object
  type_register

  install_property(
    GLib::Param::String.new(
      'name',
      'name',
      'Provider name',
      '',
      GLib::Param::READABLE | GLib::Param::WRITABLE,
    ),
  )
  install_property(
    GLib::Param::String.new(
      'prettyname',
      'prettyname',
      'Provider name for display',
      '',
      GLib::Param::READABLE | GLib::Param::WRITABLE,
    ),
  )

  attr_reader :provider_class

  def initialize(provider_class = nil)
    super()

    @provider_class = provider_class
  end

  def name = provider_class&.provider_name.to_s

  def prettyname
    if provider_class.nil?
      Providers::DISABLED_NAME
    else
      provider_class.prettyname
    end
  end

  # install_property needs a writer for each property it declares, even for
  # the read-only pair upstream derives from the provider class.
  def name=(_value)
    name
  end

  def prettyname=(_value)
    prettyname
  end
end

# The list of providers a dropdown shows.
#
# Ported from upstream's ProvidersListModel. As with LanguagesListModel, the
# Ruby bindings cannot subclass Gio::ListStore, so the model is composed
# around one and widgets are handed #model.
class ProvidersListModel
  TYPES = {
    'translators' => Providers::TRANSLATORS,
    'tts'         => Providers::TTS,
  }.freeze

  def initialize(p_type = '', show_disabled: false)
    @p_type = p_type
    @show_disabled = show_disabled
  end

  def model
    @model ||= Gio::ListStore.new(ProviderObject).tap do |store|
      store.splice(0, 0, provider_objects)
    end
  end

  def n_items = model.n_items
  def [](position) = model.get_item(position)
  def providers = Array.new(model.n_items) { |i| model.get_item(i) }

  # The position of a provider by name, or 0 when it is not in the list, which
  # is what upstream's dropdowns fall back to.
  def get_index_by_name(name)
    providers.index { |provider| provider.name == name } || 0
  end

  private

    # The providers of the requested type, or all of them when no type was
    # asked for, with the "Disabled" row first when the caller wants one.
    def provider_objects
      TYPES.fetch(@p_type, Providers::MODULES).values.map { |klass| ProviderObject.new(klass) }.then do |objects|
        if @show_disabled && !objects.empty?
          objects.unshift(ProviderObject.new)
        end

        objects
      end
    end
end
