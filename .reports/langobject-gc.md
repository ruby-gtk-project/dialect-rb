# A `GLib::Object` subclass's Ruby ivars do not survive a GC cycle once
nothing on the Ruby side references the wrapper

Found while driving `test/drive_dialect.rb`'s language-selector search step:
narrowing a `LangSelector`'s list to one match and then widening it again
came back with every language's `name` reading `nil` except the one that
happened to still be referenced elsewhere (the currently-selected one), which
in turn meant a `Gtk::StringFilter` had nothing left to match a later search
against. Not a widget bug, not a `Gtk::StringFilter` bug — the data behind
the rows was gone.

## Root cause

`LangObject` (`lib/languages.rb`) and `ProviderObject` (`lib/providers.rb`)
are both `GLib::Object` subclasses that call `install_property` (so GTK's
`Gtk::PropertyExpression`/`Gtk::StringFilter`/`Gtk::StringSorter` can read a
property off them) but back that property with a plain Ruby `attr_accessor`
ivar, set once in `initialize`.

That is fine as long as the Ruby object that `initialize` ran on is still the
object GTK is talking to. It stops being fine the moment nothing on the Ruby
side holds a direct reference to that object any more — which, for an item
sitting in a `Gio::ListStore` behind a list only displayed through a filter,
is exactly what happens once the filter hides it (the bound `Gtk::ListBox`
drops its row) and nothing else in the app happens to reference it. Ruby's
GC is then free to collect that specific wrapper object. The underlying
GObject is untouched — the `Gio::ListStore` still holds it at the C level —
but the *next* `get_item` on that position creates a **new** Ruby wrapper
around the same GObject pointer, and `initialize` never runs on it again.
Whatever lived in a plain ivar is gone; `attr_reader` on the new wrapper
returns `nil`.

## Minimal reproduction, no widgets at all

```ruby
require "gtk4"

class Thing < GLib::Object
  type_register
  install_property(
    GLib::Param::String.new("name", "name", "n", "", GLib::Param::READABLE | GLib::Param::WRITABLE)
  )
  attr_accessor :name
  def initialize(name)
    super()
    @name = name
  end
end

store = Gio::ListStore.new(Thing)
%w[English Spanish French German].each { |n| store.append(Thing.new(n)) }

puts (0...store.n_items).map { |i| store.get_item(i).name }.inspect
# => ["English", "Spanish", "French", "German"]

GC.start

puts (0...store.n_items).map { |i| store.get_item(i).name }.inspect
# => [nil, nil, nil, nil]
```

Keeping a plain Ruby array of the same objects alongside the store is enough
to keep every wrapper reachable and so keep its ivars intact:

```ruby
store = Gio::ListStore.new(Thing)
keepalive = %w[English Spanish French German].map { |n| Thing.new(n) }
keepalive.each { |t| store.append(t) }

GC.start

puts (0...store.n_items).map { |i| store.get_item(i).name }.inspect
# => ["English", "Spanish", "French", "German"]
```

## Fix applied

`LanguagesListModel#set_langs` and `ProvidersListModel#model` now each keep
every item they hand to their `Gio::ListStore` in a parallel `@items` array
for as long as the store holds them, replaced at the same point the store's
contents are replaced. Neither model needed to change its public shape —
`#[]`/`#langs`/`#providers` still read through the store, which is still the
thing GTK is bound to; the array exists purely to keep the Ruby side of each
item alive.

A more thorough fix — moving `name`/`code` (and `ProviderObject`'s derived
`name`/`prettyname`) onto real `get_property`/`set_property` overrides, so
the data lives at the GObject level and survives a rewrap on its own — would
remove the need for the keepalive array, but changes the shape of both
classes more than this round of bug-fixing called for; left here as the
better long-term fix if either class grows more properties.
