# frozen_string_literal: true

require 'adwaita'

require_relative 'settings'

# The keyboard shortcuts window.
#
# Ported from upstream's dialect/shortcuts.blp and dialect/shortcuts.py.
#
# Upstream subclasses Gtk.ShortcutsWindow and hands it to the window's
# set_help_overlay, which is what makes `win.show-help-overlay` work for free.
# Gtk::ShortcutsWindow cannot be constructed in the Ruby bindings at all —
# `Gtk::ShortcutsWindow.new` raises "GtkWindow is not subtype of
# GtkShortcutsWindow" — and GTK deprecated the whole widget in 4.18 in favour
# of Adw.ShortcutsDialog, so this is an Adwaita::ShortcutsDialog and the window
# registers its own `show-help-overlay` action to present it. The pilot port
# does the same.
#
# Upstream's one group per section becomes one Adwaita section per group, which
# is how Adw.ShortcutsDialog is laid out: the dialog holds sections, and each
# section holds items.
#
# Each item is given an action name, so Adwaita looks the accelerator up from
# what the application actually bound rather than from a string written twice.
# The one exception is upstream's `translate_shortcut`, which has no action of
# its own: its accelerator is whichever of Ctrl+Enter and Enter the user chose,
# and it is hidden entirely while live translation is on, so it is built from
# Settings here exactly as upstream's `_on_show` sets it.
class ShortcutsWindow < Adwaita::ShortcutsDialog
  # Upstream's ShortcutsGroups, in order, as title => { label => action }.
  SECTIONS = {
    'Translator'      => {
      'Switch Languages'            => 'win.switch',
      'Select source language'      => 'win.from',
      'Select destination language' => 'win.to',
      'Clear source text'           => 'win.clear',
      'Copy translation'            => 'win.copy',
      'Show Pronunciation'          => 'app.pronunciation',
      'Increase font size'          => 'win.font-size-inc',
      'Decrease font size'          => 'win.font-size-dec',
    },
    'Text-to-Speech'  => {
      'Listen to source text' => 'win.listen-src',
      'Listen to translation' => 'win.listen-dest',
    },
    'Navigation'      => {
      'Go back in history'    => 'win.back',
      'Go forward in history' => 'win.forward',
    },
    'General'         => {
      'Preferences' => 'app.preferences',
      'Shortcuts'   => 'win.show-help-overlay',
      'Quit'        => 'app.quit',
    },
  }.freeze

  TRANSLATE_LABEL = 'Translate'

  def initialize(settings: Settings.get)
    super()

    @settings = settings
    self.title = 'Keyboard Shortcuts'
  end

  # The sections this dialog was built from, in order. Adw.ShortcutsDialog
  # offers no way to read them back, and whether the Translate row is in the
  # first one is the whole of upstream's _on_show.
  attr_reader :sections

  def build
    tap do |dialog|
      @sections = SECTIONS.map do |title, items|
        section(title, items).tap { |group| dialog.add(group) }
      end
    end
  end

  # Memoized widget methods
  #
  # The Translate item lives in the first section, above the action-backed
  # ones, and only when the translation shortcut is still the user's to press.
  def translate_item
    @translate_item ||= Adwaita::ShortcutsItem.new(TRANSLATE_LABEL, @settings.translate_accel)
  end

  private

    def section(title, items)
      Adwaita::ShortcutsSection.new.tap do |group|
        group.title = title

        if title == 'Translator' && !@settings.live_translation
          group.add(translate_item)
        end

        items.each { |label, action| group.add(action_item(label, action)) }
      end
    end

    # Adwaita::ShortcutsItem takes its title and accelerator positionally —
    # keyword arguments fail even though the no-argument constructor's error
    # advertises them as keywords. An item that gets its accelerator from an
    # action is built with an empty one and then told the action's name.
    def action_item(label, action)
      Adwaita::ShortcutsItem.new(label, '').tap do |item|
        item.action_name = action
      end
    end
end
