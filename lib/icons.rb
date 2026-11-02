# frozen_string_literal: true

require 'gtk4'

# The two icons Dialect ships itself, and the loader that makes the icon
# theme find them.
#
# Ported from upstream's dialect/icons/settings-symbolic.svg,
# dialect/icons/speakers-broken-symbolic.svg and the second gresource block of
# dialect/dialect.gresource.xml, which aliases them into
# /app/drey/Dialect/icons/scalable/emblems/ as `dialect-settings-symbolic` and
# `dialect-speakers-broken-symbolic`. Adw.Application would then find them by
# its resource base path.
#
# The port builds no GResource, so the two SVGs live under data/icons in the
# layout a filesystem icon theme search path wants —
# <path>/<theme>/<size>/<context>, so hicolor/scalable/emblems, one level
# deeper than the resource aliases, which is what the theme needs to find them
# at all — and the directory is added to the display's icon theme search path
# by #load, which the application calls once at startup. The names are
# unchanged, so
# `icon-name: "dialect-settings-symbolic"` resolves exactly as upstream's
# does.
#
# `dialect-speakers-broken-symbolic` is upstream's error state for the speech
# button. The port carries the file so the asset is not lost, and will use it
# when text-to-speech lands; see the note in window.rb for why it has not.
module Icons
  # Where the icons live, relative to this file.
  SEARCH_PATH = File.expand_path('../data/icons', __dir__)

  ICON_NAMES = %w[
    dialect-settings-symbolic
    dialect-speakers-broken-symbolic
  ].freeze

  module_function

  # Adds the icon directory to the default display's icon theme. Called once
  # at startup; a second call adds nothing, so the path cannot pile up.
  def load(display: Gdk::Display.default)
    unless display.nil? || @loaded
      @loaded = true
      Gtk::IconTheme.get_for_display(display).add_search_path(SEARCH_PATH)
    end
  end

  def loaded? = @loaded == true

  # Whether the theme can resolve every icon the app asks for by name, which
  # is the only thing worth asserting about an icon search path.
  def available?(display: Gdk::Display.default)
    Gtk::IconTheme.get_for_display(display).then do |theme|
      ICON_NAMES.all? { |name| theme.has_icon?(name) }
    end
  end
end
