# frozen_string_literal: true

require 'gtk4'

# Dialect's stylesheet, and the loader that installs it on the display.
#
# Ported from upstream's dialect/style.css and dialect/style-dark.css.
#
# Upstream never loads these explicitly: both files are compiled into the app's
# GResource under /app/drey/Dialect (see dialect/dialect.gresource.xml), and
# Adw.Application picks up style.css, style-dark.css and style-hc.css from its
# resource base path on startup. The port builds no GResource, so the CSS is
# carried here as text and added to the default display by #load, which the
# application calls once at startup. Upstream's style-dark.css is empty, so
# there is no dark override to carry: a provider is only added for a
# stylesheet that has rules in it.
module Style
  # Priority Adwaita uses for an application's own stylesheet, above the theme
  # and below anything set inline on a widget.
  PRIORITY = Gtk::StyleProvider::PRIORITY_APPLICATION

  STYLESHEET = <<~CSS

    /* Main Window */
    .translation-box {
      padding: 4px 12px 12px;
    }

    .translation-box.vertical {
      padding-bottom: 0;
      padding-top: 0;
    }

    .translation-side-box textview,
    .translation-side-box text {
      background: none;
      color: inherit;
    }

    .translation-scrolled undershoot.bottom {
      border-bottom: 1px solid var(--shade-color);
    }

    .translation-scrolled.top-undershoot undershoot.top {
      border-top: 1px solid var(--shade-color);
    }

    .mistakes {
      margin: 6px;
      padding-right: 12px;
      padding-left: 12px;
      padding-top: 9px;
      padding-bottom: 9px;
      background-color: color-mix(in srgb, var(--accent-bg-color), var(--window-bg-color) 70%);
    }

    .pronunciation {
      padding: 9px;
    }

    /* Lang Selector */
    .search_box {
      background: var(--popover-bg-color);
      border-bottom: 1px solid var(--border-color);
      padding: 6px;
    }

    .lang-selector list {
      padding: 6px;
      padding-top: 4px;
    }

    .lang-selector row {
      margin-top: 2px;
    }

    .lang-selector separator {
      margin: 0 6px;
    }

    /* Actionbar */
    actionbar.flat > revealer > box {
      background: none;
      box-shadow: none;
    }

    /* Theme Switcher */
    /* Base on gnome-text-editor */
    /* https://gitlab.gnome.org/GNOME/gnome-text-editor/-/blob/main/src/style.css#L20 */
    .themeswitcher {
      margin: 9px;
    }
    .themeswitcher checkbutton {
      padding: 0;
      min-height: 44px;
      min-width: 44px;
      padding: 1px;
      background-clip: content-box;
      border-radius: 9999px;
      box-shadow: inset 0 0 0 1px var(--border-color);
    }
    .themeswitcher checkbutton.system:checked,
    .themeswitcher checkbutton.light:checked,
    .themeswitcher checkbutton.dark:checked {
      box-shadow: inset 0 0 0 2px var(--accent-bg-color);
    }
    .themeswitcher checkbutton.system {
      background-image: linear-gradient(to bottom right, #fff 49.99%, #202020 50.01%);
    }
    .themeswitcher checkbutton.light {
      background-color: #fff;
    }
    .themeswitcher checkbutton.dark {
      background-color: #202020;
    }
    .themeswitcher checkbutton radio {
      -gtk-icon-source: none;
      border: none;
      background: none;
      box-shadow: none;
      min-width: 12px;
      min-height: 12px;
      transform: translate(27px, 14px);
      padding: 2px;
    }
    .themeswitcher checkbutton.theme-selector radio:checked {
      -gtk-icon-source: -gtk-icontheme("object-select-symbolic");
      background-color: var(--accent-bg-color);
      color: var(--accent-fg-color);
    }

    /* Speech Button */
    .speech-button {
      padding: 0;
    }
    .speech-button image {
      padding: 5px 9px;
    }
    .speech-button progressbar trough {
      min-width: 34px;
    }

    /* Set GtkSourceView Caret Color */
    .dialect-sourceview {
      caret-color: var(--view-fg-color);
    }

  CSS

  # Upstream's style-dark.css carries no rules.
  DARK_STYLESHEET = ''

  module_function

  # Adds the stylesheets to the default display. Called once at startup; a
  # second call replaces nothing, so the app does not stack providers.
  def load(display: Gdk::Display.default)
    unless display.nil? || @loaded
      @loaded = true
      add(display, STYLESHEET)
      add(display, DARK_STYLESHEET)
    end
  end

  # Whether the stylesheets have been installed.
  def loaded? = @loaded == true

  def add(display, stylesheet)
    unless stylesheet.strip.empty?
      Gtk::CssProvider.new.tap do |provider|
        provider.load(data: stylesheet)
        Gtk::StyleContext.add_provider_for_display(display, provider, PRIORITY)
      end
    end
  end
end
