# frozen_string_literal: true

require 'gtk4'
require 'adwaita'

require_relative 'settings'

# The three-way light/dark/system picker that sits in the app menu.
#
# Ported from upstream's dialect/widgets/theme_switcher.blp and
# dialect/widgets/theme_switcher.py, which in turn came from GNOME Text
# Editor by way of Apostrophe. The CSS that turns the three check buttons into
# coloured circles is already carried in style.rb under `.themeswitcher`.
#
# Upstream declares `show-system` and `selected-color-scheme` as GObject
# properties so it can bind the first to Adw.StyleManager's
# `system-supports-color-schemes` and the second to the `color-scheme`
# GSetting. The port keeps the StyleManager binding — that is a real GObject
# property on a real GObject, so bind_property works — and writes the scheme
# straight through to Settings, which is a plain object here and has no
# bindable properties.
class ThemeSwitcher < Gtk::Box
  # The scheme names upstream stores in the `color-scheme` key, and the
  # Adwaita color scheme each one asks the style manager for. Upstream maps
  # "auto" to PREFER_LIGHT rather than DEFAULT, and the port follows it.
  SCHEMES = {
    'auto'  => Adwaita::ColorScheme::PREFER_LIGHT,
    'light' => Adwaita::ColorScheme::FORCE_LIGHT,
    'dark'  => Adwaita::ColorScheme::FORCE_DARK,
  }.freeze

  DEFAULT_SCHEME = 'light'

  attr_reader :selected_color_scheme

  def initialize(settings: Settings.get, style_manager: Adwaita::StyleManager.default)
    super(:horizontal, 0)

    @settings = settings
    @style_manager = style_manager
    @selected_color_scheme = settings.color_scheme.then do |scheme|
      if SCHEMES.key?(scheme)
        scheme
      else
        DEFAULT_SCHEME
      end
    end
    @applying = false

    self.hexpand = true
    add_css_class('themeswitcher')
  end

  def build
    tap do |switcher|
      switcher.append(box)

      box.tap do |container|
        container.append(system_button)
        container.append(light_button)
        container.append(dark_button)

        light_button.group = system_button
        dark_button.group = system_button

        [system_button, light_button, dark_button].zip(SCHEMES.keys).each do |button, scheme|
          button.signal_connect('notify::active') do
            on_color_scheme_changed(button, scheme)
          end
        end
      end

      # Upstream binds the system button's visibility to whether the desktop
      # can tell the app which scheme it prefers.
      # Kept in an ivar for the same reason LangRow keeps its binding: a
      # garbage-collected GLib::Binding unbinds itself.
      @show_system_binding = @style_manager.bind_property(
        'system-supports-color-schemes',
        system_button,
        'visible',
        :sync_create,
      )

      switcher.selected_color_scheme = @selected_color_scheme
    end
  end

  # Checks the matching button, tells the style manager and saves the choice,
  # which is what upstream's `selected-color-scheme` setter does.
  def selected_color_scheme=(scheme)
    SCHEMES.fetch(scheme, nil).then do |color_scheme|
      if color_scheme
        @selected_color_scheme = scheme
        @applying = true
        buttons_by_scheme.fetch(scheme).active = true
        @style_manager.color_scheme = color_scheme
        @settings.color_scheme = scheme
        @applying = false
      end
    end

    scheme
  end

  # Memoized widget methods

  def box
    @box ||= Gtk::Box.new(:horizontal, 12).tap do |container|
      container.hexpand = true
    end
  end

  def system_button = @system_button ||= scheme_button('system', 'Follow System Style')
  def light_button = @light_button ||= scheme_button('light', 'Light Style')
  def dark_button = @dark_button ||= scheme_button('dark', 'Dark Style')

  private

    def buttons_by_scheme
      @buttons_by_scheme ||= {
        'auto'  => system_button,
        'light' => light_button,
        'dark'  => dark_button,
      }
    end

    def scheme_button(style_class, tooltip)
      Gtk::CheckButton.new.tap do |button|
        button.hexpand = true
        button.halign = :center
        button.focus_on_click = false
        button.tooltip_text = tooltip
        button.add_css_class('theme-selector')
        button.add_css_class(style_class)
      end
    end

    # The three buttons share a group, so selecting one deactivates another
    # and both emit notify::active. Only the activation matters, and only when
    # the change came from the user rather than from #selected_color_scheme=.
    def on_color_scheme_changed(button, scheme)
      unless @applying || !button.active?
        self.selected_color_scheme = scheme
      end
    end
end
