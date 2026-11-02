# frozen_string_literal: true

require 'gtk4'
require 'adwaita'

require_relative 'background_task'
require_relative 'provider_errors'

# The per-provider settings subpage of the preferences dialog: the instance
# URL, the API key, and the character usage a provider that reports it shows.
#
# Ported from upstream's dialect/widgets/provider_preferences.blp and
# dialect/widgets/provider_preferences.py.
#
# Both entries validate against the service before they are saved, exactly as
# upstream does: the row goes insensitive, its suffix stack shows a spinner,
# and on a bad value the row gets the `error` class and the dialog gets a
# toast. The one difference is how the window hears about a saved value:
# upstream relies on Gio.Settings' changed::instance-url and changed::api-key
# signals, and the port's provider settings only publish an api-key observer,
# so a saved instance URL calls the window's reload through the block handed
# in at construction.
class ProviderPreferences < Adwaita::NavigationPage
  # Upstream strips the scheme and any trailing slash before validating.
  URL_PREFIX = %r{\Ahttps?://(www\.)?}

  # Adwaita::NavigationPage takes its child and title positionally — keyword
  # arguments fail, and so does a no-argument new followed by setters — so the
  # toolbar has to exist before the page does. Calling the memoized accessor
  # from the argument list is what builds it.
  def initialize(scope, dialog, window)
    super(toolbar, 'Provider Preferences')

    @scope = scope
    @dialog = dialog
    @window = window
    @provider = window.provider(scope)
  end

  def build
    tap do
      toolbar.tap do |view|
        view.add_top_bar(header)
        view.content = preferences_page

        header.title_widget = window_title
      end

      preferences_page.tap do |prefs|
        prefs.add(instance_group)
        prefs.add(api_usage_group)

        instance_group.tap do |group|
          group.add(instance_entry)
          group.add(api_key_entry)

          instance_entry.tap do |row|
            row.add_suffix(instance_stack)
            row.signal_connect('apply') { on_instance_apply }
            row.signal_connect('notify::text') { on_instance_changed }

            instance_stack.tap do |stack|
              stack.add_named(instance_reset, 'reset')
              stack.add_named(instance_spinner, 'spinner')
              stack.visible_child_name = 'reset'

              instance_reset.signal_connect('clicked') { on_reset_instance }
            end
          end

          api_key_entry.tap do |row|
            row.add_suffix(api_key_stack)
            row.signal_connect('apply') { on_api_key_apply }

            api_key_stack.tap do |stack|
              stack.add_named(api_key_reset, 'reset')
              stack.add_named(api_key_spinner, 'spinner')
              stack.visible_child_name = 'reset'

              api_key_reset.signal_connect('clicked') { on_reset_api_key }
            end
          end
        end

        api_usage_group.tap do |group|
          group.add(api_usage_box)

          api_usage_box.tap do |box|
            box.append(api_usage)
            box.append(api_usage_label)
          end
        end
      end

      # Upstream greys the whole page out while the translator reloads, and
      # re-reads the provider object once it has.
      @window.on_translator_loading do |loading|
        preferences_page.sensitive = !loading

        unless loading
          @provider = @window.provider(@scope)
          check_settings
        end
      end

      load_provider
    end
  end

  # Memoized widget methods

  def toolbar = @toolbar ||= Adwaita::ToolbarView.new
  def header = @header ||= Adwaita::HeaderBar.new
  # Named window_title, not title: Adwaita::NavigationPage already has a
  # `title` property, and shadowing it would hide the page's own title from
  # the navigation view.
  def window_title = @window_title ||= Adwaita::WindowTitle.new('Provider Preferences', '')
  def preferences_page = @preferences_page ||= Adwaita::PreferencesPage.new
  def instance_group = @instance_group ||= Adwaita::PreferencesGroup.new

  def instance_entry
    @instance_entry ||= Adwaita::EntryRow.new.tap do |row|
      row.title = 'Instance URL'
      row.tooltip_text = 'Enter an Instance URL for the Provider.'
      row.show_apply_button = true
    end
  end

  def instance_stack = @instance_stack ||= Gtk::Stack.new
  def instance_reset = @instance_reset ||= reset_button
  def instance_spinner = @instance_spinner ||= suffix_spinner

  def api_key_entry
    @api_key_entry ||= Adwaita::PasswordEntryRow.new.tap do |row|
      row.title = 'API Key'
      row.tooltip_text = 'Enter an API Key for the Provider.'
      row.show_apply_button = true
    end
  end

  def api_key_stack = @api_key_stack ||= Gtk::Stack.new
  def api_key_reset = @api_key_reset ||= reset_button
  def api_key_spinner = @api_key_spinner ||= suffix_spinner

  def api_usage_group
    @api_usage_group ||= Adwaita::PreferencesGroup.new.tap do |group|
      group.title = 'Character Usage'
      group.visible = false
    end
  end

  def api_usage_box = @api_usage_box ||= Gtk::Box.new(:vertical, 3)
  def api_usage = @api_usage ||= Gtk::LevelBar.new
  def api_usage_label = @api_usage_label ||= Gtk::Label.new

  private

    def reset_button
      Gtk::Button.new.tap do |button|
        button.tooltip_text = 'Reset to Default'
        button.icon_name = 'view-refresh-symbolic'
        button.valign = :center
        button.add_css_class('flat')
      end
    end

    def suffix_spinner
      Adwaita::Spinner.new.tap do |spinner|
        spinner.valign = :center
      end
    end

    # Upstream's __init__ tail: name the provider, decide which rows apply,
    # and fill them with the saved values.
    def load_provider
      with_provider do |provider|
        window_title.subtitle = provider.prettyname
        check_settings
        instance_entry.text = provider.instance_url
        api_key_entry.text = provider.api_key
      end
    end

    def check_settings
      with_provider do |provider|
        instance_entry.visible = provider.supports_instances?
        api_key_entry.visible = provider.supports_api_key?
        api_usage_group.visible = false

        if provider.supports_api_usage?
          load_api_usage(provider)
        end
      end
    end

    def load_api_usage(provider)
      BackgroundTask.run(
        on_success: ->(usage) { show_api_usage(usage) },
        on_error:   ->(_exc) { api_usage_group.visible = false },
      ) { provider.api_char_usage }
    end

    def show_api_usage(usage)
      usage.then do |(used, limit)|
        if limit.to_f.positive?
          api_usage.value = used.to_f / limit
          api_usage_label.label = "#{used} of #{limit} characters"
          api_usage_group.visible = true
        end
      end
    end

    # --- instance URL ---------------------------------------------------

    def on_instance_apply
      with_provider do |provider|
        instance_entry.text.to_s.sub(URL_PREFIX, '').strip.delete_suffix('/').then do |new_url|
          if new_url == provider.instance_url
            instance_entry.remove_css_class('error')
          else
            validate_instance(provider, new_url)
          end
        end
      end
    end

    def validate_instance(provider, new_url)
      start_validating(instance_stack)

      BackgroundTask.run(
        on_success: ->(valid) { instance_validated(provider, new_url, valid) },
        on_error:   ->(exc) { instance_validation_failed(exc) },
      ) { provider.validate_instance(new_url) }
    end

    def instance_validated(provider, new_url, valid)
      if valid
        provider.instance_url = new_url
        provider.reset_src_langs
        provider.reset_dest_langs
        instance_entry.remove_css_class('error')
        instance_entry.text = provider.instance_url
        @window.reload_provider(reload_kind)
      else
        instance_entry.add_css_class('error')
        @dialog.add_toast(Adwaita::Toast.new("Not a valid #{provider.prettyname} instance"))
      end

      stop_validating(instance_stack)
    end

    def instance_validation_failed(exc)
      case exc
      when RequestError
        @dialog.add_toast(Adwaita::Toast.new('Failed validating instance, check for network issues'))
      else
        @dialog.add_toast(Adwaita::Toast.new(exc.message))
      end

      stop_validating(instance_stack)
    end

    def on_instance_changed
      with_provider do |provider|
        instance_entry.show_apply_button = instance_entry.text != provider.instance_url
      end
    end

    def on_reset_instance
      with_provider do |provider|
        unless provider.instance_url == provider.class.defaults[:instance_url]
          provider.reset_instance_url
        end

        instance_entry.remove_css_class('error')
        instance_entry.text = provider.instance_url
        @window.reload_provider(reload_kind)
      end
    end

    # --- API key --------------------------------------------------------

    def on_api_key_apply
      with_provider do |provider|
        api_key_entry.text.to_s.then do |new_key|
          if new_key == provider.api_key
            api_key_entry.remove_css_class('error')
          else
            validate_api_key(provider, new_key)
          end
        end
      end
    end

    def validate_api_key(provider, new_key)
      start_validating(api_key_stack)

      BackgroundTask.run(
        on_success: ->(valid) { api_key_validated(provider, new_key, valid) },
        on_error:   ->(exc) { api_key_validation_failed(exc) },
      ) { provider.validate_api_key(new_key) }
    end

    def api_key_validated(provider, new_key, valid)
      if valid
        provider.api_key = new_key
        api_key_entry.remove_css_class('error')
        api_key_entry.text = provider.api_key
      else
        api_key_entry.add_css_class('error')
        @dialog.add_toast(Adwaita::Toast.new("Not a valid #{provider.prettyname} API key"))
      end

      stop_validating(api_key_stack)
    end

    def api_key_validation_failed(exc)
      case exc
      when RequestError
        @dialog.add_toast(Adwaita::Toast.new('Failed validating API key, check for network issues'))
      else
        @dialog.add_toast(Adwaita::Toast.new(exc.message))
      end

      stop_validating(api_key_stack)
    end

    def on_reset_api_key
      with_provider do |provider|
        unless provider.api_key == provider.class.defaults[:api_key]
          provider.reset_api_key
        end

        api_key_entry.remove_css_class('error')
        api_key_entry.text = provider.api_key
      end
    end

    # --- shared ---------------------------------------------------------

    def start_validating(stack)
      instance_entry.sensitive = false
      api_key_entry.sensitive = false
      stack.visible_child_name = 'spinner'
    end

    def stop_validating(stack)
      instance_entry.sensitive = true
      api_key_entry.sensitive = true
      stack.visible_child_name = 'reset'
    end

    # The kind name the window's reload_provider takes for this scope.
    def reload_kind
      if @scope == 'tts'
        'tts'
      else
        'translator'
      end
    end

    def with_provider
      @provider.then do |provider|
        if provider
          yield provider
        end
      end
    end
end
