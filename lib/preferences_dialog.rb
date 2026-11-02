# frozen_string_literal: true

require 'gtk4'
require 'adwaita'

require_relative 'provider_preferences'
require_relative 'providers'
require_relative 'settings'

# The preferences dialog: the provider pickers, the behaviour toggles and the
# font size.
#
# Ported from upstream's dialect/preferences.ui and dialect/preferences.py.
#
# Upstream binds every row straight to a GSettings key with
# Gio.Settings.bind. The port's Settings is a plain object backed by a JSON
# file, so each row writes through on its change signal instead — the same
# keys, the same defaults, the same moment.
#
# The search-provider row is still hidden outside GNOME, as upstream does, and
# the TTS row is still hidden when no loaded provider speaks.
class PreferencesDialog < Adwaita::PreferencesDialog
  TRANSLATE_ACCELS = ['Ctrl + Enter', 'Enter'].freeze

  # The provider settings button's two tooltips, upstream's
  # _provider_settings_tooltip.
  SETTINGS_TOOLTIP = 'Edit Provider Settings'
  NO_SETTINGS_TOOLTIP = 'No Settings for This Provider'

  FONT_SIZE_LOWER = 6
  FONT_SIZE_UPPER = 72
  FONT_SIZE_STEP = 5
  FONT_SIZE_PAGE = 10

  def initialize(window, settings: Settings.get)
    super()

    @window = window
    @settings = settings
    @loading = false
    self.title = 'Preferences'
  end

  def build
    tap do |dialog|
      dialog.add(page)

      page.tap do |prefs|
        prefs.add(providers_group)
        prefs.add(behavior_group)
        prefs.add(appearance_group)
      end

      build_providers_group
      build_behavior_group
      build_appearance_group

      # Upstream greys both provider rows out while the translator reloads.
      @window.on_translator_loading do |loading|
        translator_row.sensitive = !loading
        tts_row.sensitive = !loading
      end
    end
  end

  # Memoized widget methods

  def page = @page ||= Adwaita::PreferencesPage.new

  def providers_group
    @providers_group ||= Adwaita::PreferencesGroup.new.tap do |group|
      group.title = 'Providers'
    end
  end

  def translator_row
    @translator_row ||= provider_row(
      'Translator',
      'Choose from the available translation services.',
    )
  end

  def translator_config = @translator_config ||= config_button
  def translator_separator = @translator_separator ||= row_separator

  def tts_row
    @tts_row ||= provider_row(
      'Text-to-Speech',
      'Choose from the available TTS services.',
    )
  end

  def tts_config = @tts_config ||= config_button
  def tts_separator = @tts_separator ||= row_separator

  def behavior_group
    @behavior_group ||= Adwaita::PreferencesGroup.new.tap do |group|
      group.title = 'Behavior'
    end
  end

  def live_translation
    @live_translation ||= Adwaita::ExpanderRow.new.tap do |row|
      row.title = 'Live Translation'
      row.subtitle = 'Warning: Your IP address may get banned for API abuse.'
      row.show_enable_switch = true
      row.expanded = true
    end
  end

  def search_provider
    @search_provider ||= Adwaita::SwitchRow.new.tap do |row|
      row.title = 'Show Translations in Desktop Search'
      row.subtitle = 'Warning: All desktop searches will be sent to the translation service'
    end
  end

  def translate_accel
    @translate_accel ||= Adwaita::ComboRow.new.tap do |row|
      row.title = 'Translation Shortcut'
      row.subtitle = 'The unselected choice will be used for line break.'
      row.model = Gtk::StringList.new(TRANSLATE_ACCELS)
    end
  end

  def src_auto
    @src_auto ||= Adwaita::SwitchRow.new.tap do |row|
      row.title = 'Default to Auto'
      row.subtitle = 'Use "Auto" as the default language'
    end
  end

  def appearance_group
    @appearance_group ||= Adwaita::PreferencesGroup.new.tap do |group|
      group.title = 'Appearance'
    end
  end

  def custom_default_font_size
    @custom_default_font_size ||= Adwaita::ExpanderRow.new.tap do |row|
      row.title = 'Use Custom Font Size'
      row.subtitle = 'System font size is used otherwise.'
      row.show_enable_switch = true
      row.expanded = true
    end
  end

  def font_size_adjustment
    @font_size_adjustment ||= Gtk::Adjustment.new(
      0,
      FONT_SIZE_LOWER,
      FONT_SIZE_UPPER,
      FONT_SIZE_STEP,
      FONT_SIZE_PAGE,
      0,
    )
  end

  def default_font_size
    @default_font_size ||= Adwaita::SpinRow.new(font_size_adjustment, 1, 0).tap do |row|
      row.title = 'Default Font Size'
      row.subtitle = 'Changing the size via shortcuts does not overwrite this.'
    end
  end

  private

    def provider_row(title, subtitle)
      Adwaita::ComboRow.new.tap do |row|
        row.title = title
        row.subtitle = subtitle
        row.title_lines = 1
        row.subtitle_lines = 3
        row.expression = Gtk::PropertyExpression.new(ProviderObject, nil, 'prettyname')
      end
    end

    def config_button
      Gtk::Button.new.tap do |button|
        button.valign = :center
        button.icon_name = 'dialect-settings-symbolic'
        button.sensitive = false
        button.tooltip_text = NO_SETTINGS_TOOLTIP
      end
    end

    # Upstream's preferences.ui leaves the separator's orientation unset,
    # which in GTK means horizontal, but gives it start, top and bottom
    # margins — the insets of a vertical divider between the combo row and
    # its settings button. It is built vertical here so it renders as the
    # divider those margins describe.
    def row_separator
      Gtk::Separator.new(:vertical).tap do |separator|
        separator.margin_start = 12
        separator.margin_top = 12
        separator.margin_bottom = 12
      end
    end

    # --- providers -------------------------------------------------------

    def build_providers_group
      providers_group.tap do |group|
        group.add(translator_row)
        group.add(tts_row)

        translator_row.tap do |row|
          row.add_suffix(translator_separator)
          row.add_suffix(translator_config)

          translator_config.signal_connect('clicked') { open_provider('trans') }
        end

        tts_row.tap do |row|
          row.add_suffix(tts_separator)
          row.add_suffix(tts_config)

          tts_config.signal_connect('clicked') { open_provider('tts') }
        end
      end

      setup_translator_row
      setup_tts_row
    end

    def setup_translator_row
      @translator_model = ProvidersListModel.new('translators')

      translator_row.tap do |row|
        row.freeze_notify do
          row.model = @translator_model.model
          row.selected = @translator_model.get_index_by_name(@settings.active_translator)
        end

        update_config_button(translator_config, @settings.active_translator)
        row.signal_connect('notify::selected') { switch_translator }
      end
    end

    def setup_tts_row
      if Providers::TTS.empty?
        tts_row.visible = false
      else
        @tts_model = ProvidersListModel.new('tts', show_disabled: true)

        tts_row.tap do |row|
          row.freeze_notify do
            row.model = @tts_model.model
            row.selected = @tts_model.get_index_by_name(@settings.active_tts)
          end

          update_config_button(tts_config, @settings.active_tts)
          row.signal_connect('notify::selected') { switch_tts }
        end
      end
    end

    def switch_translator
      selected_name(translator_row).then do |name|
        update_config_button(translator_config, name)

        unless name == @settings.active_translator
          @settings.active_translator = name
        end
      end
    end

    def switch_tts
      selected_name(tts_row).then do |name|
        update_config_button(tts_config, name)

        unless name == @settings.active_tts
          @settings.active_tts = name
        end
      end
    end

    def selected_name(row) = row.selected_item&.name.to_s

    # Upstream's _provider_has_settings plus _provider_settings_tooltip.
    def update_config_button(button, name)
      provider_has_settings?(name).then do |has_settings|
        button.sensitive = has_settings

        if has_settings
          button.tooltip_text = SETTINGS_TOOLTIP
        else
          button.tooltip_text = NO_SETTINGS_TOOLTIP
        end
      end
    end

    def provider_has_settings?(name)
      Providers[name.to_s].then do |provider_class|
        if provider_class.nil?
          false
        else
          (provider_class.features & (ProviderFeature::INSTANCES | ProviderFeature::API_KEY)) != 0
        end
      end
    end

    def open_provider(scope)
      @window.provider(scope).then do |provider|
        if provider
          push_subpage(ProviderPreferences.new(scope, self, @window).build)
        end
      end
    end

    # --- behaviour -------------------------------------------------------

    def build_behavior_group
      behavior_group.tap do |group|
        group.add(live_translation)
        group.add(translate_accel)
        group.add(src_auto)

        live_translation.tap do |row|
          row.add_row(search_provider)
          row.enable_expansion = @settings.live_translation

          row.signal_connect('notify::enable-expansion') do
            @settings.live_translation = row.enable_expansion?
            translate_accel.sensitive = !row.enable_expansion?
          end
        end

        search_provider.tap do |row|
          row.active = @settings.sp_translation
          row.signal_connect('notify::active') { @settings.sp_translation = row.active? }

          # Upstream hides the row outside GNOME, where there is no Shell
          # search provider to feed.
          row.visible = ENV.fetch('XDG_CURRENT_DESKTOP', '') == 'GNOME'
        end

        translate_accel.tap do |row|
          row.selected = @settings.translate_accel_value
          row.sensitive = !@settings.live_translation

          row.signal_connect('notify::selected') do
            @settings['translate-accel'] = row.selected
            @window.apply_translate_accel
          end
        end

        src_auto.tap do |row|
          row.active = @settings.src_auto
          row.signal_connect('notify::active') { @settings.src_auto = row.active? }
        end
      end
    end

    # --- appearance ------------------------------------------------------

    def build_appearance_group
      appearance_group.tap do |group|
        group.add(custom_default_font_size)

        custom_default_font_size.tap do |row|
          row.add_row(default_font_size)
          row.enable_expansion = @settings.custom_default_font_size

          row.signal_connect('notify::enable-expansion') { on_custom_font_size_switched(row) }
        end

        default_font_size.tap do |row|
          row.value = font_size_value

          font_size_adjustment.signal_connect('value-changed') do |adjustment|
            on_font_size_changed(adjustment)
          end
        end
      end
    end

    # The saved size, or the system one when the user has never set one, so
    # the spin row never opens on its lower bound.
    def font_size_value
      @settings.default_font_size.then do |size|
        if size.zero?
          @settings.system_font_size
        else
          size
        end
      end
    end

    # Upstream's _custom_default_font_size_switch: turning the switch on for
    # the first time adopts the system size, turning it off goes back to it.
    def on_custom_font_size_switched(row)
      @settings.system_font_size.then do |system_size|
        if !row.enable_expansion?
          @settings.custom_default_font_size = false
          @window.set_font_size(system_size)
        elsif @settings.default_font_size.zero?
          @settings.custom_default_font_size = true
          @settings.default_font_size = system_size
          default_font_size.value = system_size
          @window.set_font_size(system_size)
        else
          @settings.custom_default_font_size = true
          @window.set_font_size(@settings.default_font_size)
        end
      end
    end

    def on_font_size_changed(adjustment)
      adjustment.value.to_i.then do |size|
        @settings.default_font_size = size
        @window.set_font_size(size)
      end
    end
end
