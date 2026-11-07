# frozen_string_literal: true

require 'gtk4'

require_relative 'define'

# Dialect's language objects and the list model the selector popovers show.
#
# Ported from upstream's dialect/languages.py.
#
# Upstream's LanguagesListModel implements Gio.ListModel itself, overriding
# do_get_item/do_get_n_items over a plain Python list. The Ruby bindings give
# no equivalent: `type_register` replaces a GLib::Object subclass's
# `initialize` with one that takes no arguments, so a Gio::ListStore subclass
# can never pass its construct-only `item-type` up to the parent. The model is
# therefore composed around a Gio::ListStore rather than inheriting one, and
# widgets are handed `#model`.
module Languages
  module_function

  # The CLDR name for a language code, or nil when CLDR has none.
  #
  # Upstream additionally runs the name through gettext's pgettext with the
  # code as the message context, which is how the dialect-cldr-langs domain
  # localizes language names. The port carries no compiled message catalogs,
  # so the CLDR name is returned as-is.
  def lang_name(code) = Define::LANGUAGES[code]
end

# A single language in a list model: its code, the name to display, and
# whether it is the one currently selected.
#
# Ported from upstream's LangObject.
class LangObject < GLib::Object
  type_register

  install_property(
    GLib::Param::String.new(
      'code',
      'code',
      'Language code',
      '',
      GLib::Param::READABLE | GLib::Param::WRITABLE,
    ),
  )
  install_property(
    GLib::Param::String.new(
      'name',
      'name',
      'Language name',
      '',
      GLib::Param::READABLE | GLib::Param::WRITABLE,
    ),
  )
  install_property(
    GLib::Param::Boolean.new(
      'selected',
      'selected',
      'Whether this language is selected',
      false,
      GLib::Param::READABLE | GLib::Param::WRITABLE,
    ),
  )

  attr_accessor :code, :name

  def initialize(code, name, selected: false)
    super()

    @code = code
    @name = name
    @selected = selected
  end

  attr_reader :selected

  # Notifies so the rows bound to this object can redraw their check mark.
  def selected=(value)
    @selected = value
    notify('selected')
  end

  def to_s = code
end

# The list of languages a selector shows, rebuilt whenever the active
# provider's language list changes.
#
# Ported from upstream's LanguagesListModel.
class LanguagesListModel
  AUTO_NAME = 'Auto'

  attr_reader :names_func

  def initialize(names_func: Languages.method(:lang_name))
    @names_func = names_func
    # Every LangObject the store currently holds, kept alive on the Ruby
    # side.
    #
    # `LangObject#code`/`#name` are plain Ruby ivars (see its class comment);
    # `Gio::ListStore` only holds the underlying GObject, and once nothing on
    # the Ruby side still references an item — which, for anything the user
    # has filtered out of a `LangSelector`'s search, is exactly the state
    # between one GC run and the next — the bindings hand back a freshly
    # rewrapped Ruby object around that same GObject on the next `get_item`,
    # with `initialize` never having run on it again, so `code` and `name`
    # read back `nil`. Observed here as a language selector's search
    # narrowing the list to one match and then widening it again losing the
    # names of every language besides the one still selected elsewhere.
    # Holding each item in this array for as long as the model does, deleted
    # at the same two sites the store is, keeps the original Ruby object (and
    # its ivars) alive regardless of what GTK currently has on screen.
    @items = []
  end

  # The Gio::ListModel to hand to GTK widgets.
  def model = @model ||= Gio::ListStore.new(LangObject)

  def n_items = model.n_items
  def [](position) = model.get_item(position)
  def langs = Array.new(model.n_items) { |i| model.get_item(i) }

  def each(&block)
    langs.each(&block)
  end

  # Replaces the whole list in one items-changed emission, matching upstream's
  # single `items_changed(0, removed, len(self.langs))` call.
  def set_langs(codes, auto: false)
    codes.map { |code| LangObject.new(code, names_func.call(code) || code) }.then do |items|
      if auto
        items.unshift(LangObject.new('auto', AUTO_NAME))
      end

      model.splice(0, model.n_items, items)
      @items = items
    end
  end

  def set_selected(code)
    each { |item| item.selected = item.code == code }
  end
end
