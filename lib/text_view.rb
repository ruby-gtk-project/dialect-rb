# frozen_string_literal: true

require 'gtk4'

require_relative 'settings'

# The text view both halves of the translation box are built from: a text view
# that activates on Enter (or Ctrl+Enter), and whose font size the user can
# change with Ctrl+scroll.
#
# Ported from upstream's dialect/widgets/textview.py.
#
# Two deliberate departures from upstream, both forced by what the Ruby
# bindings ship:
#
# * Upstream subclasses GtkSource.View so it can hang a GtkSourceView spell
#   checker off the buffer. There is no GtkSourceView typelib in the dev
#   shell — and no Spelling typelib either, so the spell checker upstream's
#   window installs has nothing to attach to — so this subclasses
#   Gtk::TextView. Everything upstream's TextView itself does (wrapping, the
#   activate signal, the font-size CSS provider, the two controllers) is a
#   plain GtkTextView behaviour and is carried over unchanged. The
#   `dialect-sourceview` CSS class is still applied, so style.css's caret
#   colour rule still matches.
# * Upstream declares `activate` as a GObject signal and `font-size` as a
#   GObject property, then binds the two views' font sizes together with
#   GObject.BindingFlags.BIDIRECTIONAL. A GLib::Object subclass in the Ruby
#   bindings cannot declare its own signals without a full type registration,
#   and `type_register` replaces `initialize` with one that takes no
#   arguments, which a widget constructed with callbacks cannot use. So
#   activation and font-size changes are delivered to blocks handed in at
#   construction, and the window keeps the two views in step by passing each
#   the other's setter.
class TextView < Gtk::TextView
  # Upstream's font_size_inc/font_size_dec step, and the floor the decrement
  # refuses to go below.
  FONT_STEP = 5
  MIN_FONT_SIZE = 6

  # The GTK priority upstream's view installs its font provider at: above the
  # app stylesheet, so the font size wins over style.css.
  FONT_PRIORITY = Gtk::StyleProvider::PRIORITY_USER

  # The two key values upstream treats as activation.
  ENTER_KEYS = [Gdk::Keyval::KEY_Return, Gdk::Keyval::KEY_KP_Enter].freeze

  attr_reader :font_size

  # Whether activation requires the mod key, upstream's `activate-mod`.
  attr_accessor :activate_mod

  def initialize(editable: true, on_activate: nil, on_font_size_changed: nil, settings: Settings.get)
    super()

    @on_activate = on_activate
    @on_font_size_changed = on_font_size_changed
    @activate_mod = true
    @font_size = settings.system_font_size

    self.editable = editable
    self.wrap_mode = :word_char
    self.left_margin = 9
    self.right_margin = 9
    self.top_margin = 9
    self.bottom_margin = 9
    add_css_class('dialect-sourceview')
  end

  def build
    tap do |view|
      view.style_context.add_provider(font_provider, FONT_PRIORITY)
      view.add_controller(key_controller)
      view.add_controller(scroll_controller)

      key_controller.tap do |controller|
        controller.signal_connect('key-pressed') do |_controller, keyval, _keycode, state|
          on_key_pressed(keyval, state)
        end
      end

      scroll_controller.tap do |controller|
        controller.signal_connect('scroll') do |controller_, _dx, dy|
          on_scroll(controller_, dy)
        end
      end

      view.font_size = @font_size
    end
  end

  # Writes the size into the view's own CSS provider, which is how upstream
  # applies it, and tells whoever asked to be told.
  def font_size=(value)
    @font_size = value
    font_provider.load(data: "textview { font-size: #{value}pt; }")
    @on_font_size_changed&.call(value)
    value
  end

  # Sets the size without calling back, so two views kept in step by each
  # other's setter cannot bounce the change back and forth.
  def font_size_quietly=(value)
    @font_size = value
    font_provider.load(data: "textview { font-size: #{value}pt; }")
    value
  end

  def font_size_inc
    self.font_size = font_size + FONT_STEP
  end

  def font_size_dec
    (font_size - FONT_STEP).then do |new_size|
      if new_size >= MIN_FONT_SIZE
        self.font_size = new_size
      end
    end
  end

  # The whole buffer's text, which every caller in the window wants.
  def text = buffer.get_text(buffer.start_iter, buffer.end_iter, true)

  def text=(value)
    buffer.text = value.to_s
  end

  def char_count = buffer.char_count

  # Memoized widget methods

  def font_provider = @font_provider ||= Gtk::CssProvider.new
  def key_controller = @key_controller ||= Gtk::EventControllerKey.new
  def scroll_controller = @scroll_controller ||= Gtk::EventControllerScroll.new(:vertical)

  private

    # Returns true to stop the event, as upstream's Gdk.EVENT_STOP does.
    def on_key_pressed(keyval, state)
      (state & Gtk.accelerator_get_default_mod_mask).then do |modifiers|
        if !ENTER_KEYS.include?(keyval)
          false
        elsif modifiers == Gdk::ModifierType::CONTROL_MASK
          activate_mod && emit_activate
        else
          !activate_mod && emit_activate
        end
      end
    end

    def emit_activate
      @on_activate&.call
      true
    end

    # Ctrl+scroll changes the font size; anything else is left to the
    # scrolled window.
    def on_scroll(controller, delta_y)
      if controller.current_event_state == Gdk::ModifierType::CONTROL_MASK
        if delta_y > 0
          font_size_dec
        else
          font_size_inc
        end

        true
      else
        false
      end
    end
end
