# frozen_string_literal: true

require 'gtk4'

# The app menu behind the hamburger button.
#
# Ported from the `menu app-menu` block at the top of upstream's
# dialect/window.blp: three sections, the first of which is a custom slot the
# window fills with the ThemeSwitcher.
#
# The custom slot is a menu item carrying the `custom` attribute, which is
# exactly what Blueprint's `custom: "theme"` compiles to; the window then calls
# `popover.add_child(theme_switcher, 'theme')` to put a widget in it.
class MainMenu
  # The id the theme switcher is added to the popover under.
  THEME_SLOT = 'theme'

  # The two action-backed sections, as label => detailed action name.
  PREFERENCES_ITEMS = {
    'Show Pronunciation' => 'app.pronunciation',
  }.freeze

  HELP_ITEMS = {
    'Preferences'        => 'app.preferences',
    'Keyboard Shortcuts' => 'win.show-help-overlay',
    'About Dialect'      => 'app.about',
  }.freeze

  def build
    menu.tap do |model|
      model.append_section(nil, theme_section)
      model.append_section(nil, preferences_section)
      model.append_section(nil, help_section)
    end
  end

  # Memoized model methods

  def menu = @menu ||= Gio::Menu.new

  def theme_section
    @theme_section ||= Gio::Menu.new.tap do |section|
      section.append_item(theme_item)
    end
  end

  def theme_item
    @theme_item ||= Gio::MenuItem.new.tap do |item|
      item.set_attribute_value('custom', GLib::Variant.new(THEME_SLOT))
    end
  end

  def preferences_section = @preferences_section ||= section_for(PREFERENCES_ITEMS)
  def help_section = @help_section ||= section_for(HELP_ITEMS)

  private

    def section_for(items)
      Gio::Menu.new.tap do |section|
        items.each { |label, action| section.append(label, action) }
      end
    end
end
