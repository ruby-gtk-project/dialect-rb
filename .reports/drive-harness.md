# Driving the dialect port

`test/drive_dialect.rb` (plus `test/gtk_driver.rb`, copied unchanged from the
reference harness in `tally-rb`) builds the real application under Xvfb,
asserts every component the port claims, and writes screenshots to
`tmp/shots/`.

    nix develop --command xvfb-run -a ruby test/drive_dialect.rb

Last run (2026-11-07): **536 of 536 checks passed — DRIVE OK**, 42 steps, 9
screenshots, confirmed over two consecutive clean runs.

## What it covers

Widget components, driven through the live window (25 steps): the
application and its id, the `Adwaita::ApplicationWindow` and its restored
size, the four stack pages and the switch between them, the error and
API-key views and their message variants, the `Adwaita::MultiLayoutView` with
both layouts and all five slots, the narrow-window breakpoint and the five
changes it applies, the app menu's three sections, the theme switcher writing
through to the style manager and to settings, both language selectors — their
sorted lists, their check marks, their search and their recent lists — the two
text views and the font size they share, every window and app action with its
accelerator, the character counter and the provider's character limit, a
translation end to end with its history, mistakes row and pronunciation rows,
switching languages, the suggestion editor, copy and paste through the real
clipboard, the shortcuts window, the preferences dialog and its provider
subpage, the About dialog, the icon assets, the command line parser, and the
window's close-request handler.

Non-widget components, driven against real files and real sockets (17 steps):
`Define`, `Utils`, the provider error hierarchy, `Languages`, `LangObject`,
`LanguagesListModel`, `Session`, `SessionHelpers`, `BackgroundTask`,
`Provider`, the four translation Data classes, `ProviderSettings`,
`Providers`, `ProviderObject`, `ProvidersListModel`, `Settings`, `Style`, and
each of the seven provider modules.

## Nothing touches the network

`Session` and `SessionHelpers` are driven against a loopback `TCPServer` the
script starts itself, and the window is driven against `DriveProvider`, a
translation provider defined at the top of the script and registered into
`Providers` like any other. Every provider upstream ships reaches its service
in `init_trans` — Google fetches its language list on startup — so driving the
real window against a real provider would make the run depend on the
internet. `DriveProvider` answers from memory: four languages, a 120-character
limit, and a translation that reverses the text, with a mistake and both
pronunciations so those rows can be asserted. The three checks that count the
provider registry subtract it by name.

## What it deliberately does not cover

The last step asserts the absence of what this round left out, so the script
cannot be mistaken for covering it:

- **Text-to-speech** — the speech button (`lib/speech_button.rb`), the
  `win.listen-src` and `win.listen-dest` actions and their accelerators. There
  is no Gst typelib in the dev shell, so there is nothing to play a provider's
  audio with. `dialect-speakers-broken-symbolic` is carried in `data/icons`
  regardless, and the step checks the icon theme still resolves it.
- **Spell checking** — no Spelling typelib, so upstream's
  `setup_spell_checking` has nothing to attach to the source buffer.
- **The GNOME Shell search provider** (`lib/search_provider.rb`) and the
  **translation catalogs** (`po/`).

## Bugs this found

1. The application never called `Adwaita.init`. Because `Adwaita::Application`
   is broken in the Ruby bindings the port uses `Gtk::Application`, which does
   not run `adw_init()` — so libadwaita's stylesheet was never installed and
   every Adwaita widget rendered as an unstyled GTK box. Fixed in the
   application; `Adwaita.initialized?` is now a check.
2. `Gtk::CustomSorter`'s block is handed its two items as raw pointers, which
   arrive in Ruby as Integers, so a sort closure has nothing to compare. The
   language list now sorts with a `Gtk::StringSorter` over a
   `Gtk::PropertyExpression` on `LangObject#name`, and filters with a
   `Gtk::StringFilter` in substring mode.
3. `Gtk::StringSorter.new(expression)` and `Gtk::StringFilter.new(expression)`
   print a `GLib-GObject-CRITICAL` on every construction — the constructor
   argument is transfer-full and the bindings hand it an unboxed
   `GtkExpression`. Passing `nil` and setting `expression=` afterwards is
   silent and works.
4. `Adwaita::Breakpoint#add_setter` fails `G_IS_VALUE` for anything but a
   string, silently dropping the setter. The breakpoint's five changes are
   made in its `apply` and `unapply` handlers instead.
5. `GLib.markup_escape_text` is not bound, so the error view escapes the three
   characters Pango cares about itself. Upstream interpolates the exception
   raw and would drop the whole description on an ampersand.
6. A `GLib::Binding` whose Ruby wrapper is garbage collected unbinds itself.
   `LangRow` and `ThemeSwitcher` keep theirs in an ivar; without that the
   language rows' check marks stopped following the model.
7. `Gtk::Widget#visible?` answers `gtk_widget_is_visible`, not the widget's own
   flag, so it is false for everything inside a popover that has never been
   shown. Checks on popover contents read the `visible` property instead.
8. A `GLib::Object` subclass whose state lives in plain Ruby ivars loses that
   state across a GC cycle once nothing on the Ruby side holds a direct
   reference to it any more — the ruby-gnome bindings hand back a freshly
   rewrapped Ruby object around the same underlying GObject on the next
   `Gio::ListStore#get_item`, and `initialize` never runs on it again. Found
   via `LangObject` (`lib/languages.rb`): a language selector's search
   narrowing the list to one match and then widening it again came back with
   `name`/`code` reading `nil` for every language besides the one still held
   alive elsewhere (the one currently selected), which a `Gtk::StringFilter`
   then has nothing to match against. `LanguagesListModel` and
   `ProvidersListModel` now each keep their own items in a plain Ruby array
   for as long as their `Gio::ListStore` does, which is enough to keep them
   alive regardless of what GTK currently has on screen. Written up in full,
   with a minimal reproduction outside any widget, in
   `.reports/langobject-gc.md`.
9. `Gio::Error` (the hierarchy `Gio::IOError::ConnectionRefused` and
   `Gio::IOError::PartialInput` come from) is not a `GLib::Error` — the two
   only share `GLib::ErrorInfo` as a common ancestor, they are not one a
   subclass of the other. `Session::NETWORK_ERRORS` in `lib/session.rb`
   caught only `GLib::Error`, so a transport failure surfacing through GIO's
   own hierarchy instead of libsoup's came back as a raw, unconverted
   exception rather than a `ResponseError`. Added `Gio::Error` to the list.
10. This sandbox's network stack does not refuse a connection to a privileged,
    nothing-listening port (`127.0.0.1:1`) the way a real kernel does. The
    first drive run routed that attempt somewhere that wedged the forked
    `HttpProbe`'s single-threaded accept loop on a connection that never sent
    anything, so every real request to the probe after the first "refused"
    one then failed for real. `test/drive_dialect.rb` now provokes a refused
    connection with an unprivileged ephemeral port it just vacated instead,
    which the kernel refuses cleanly and which disturbs nothing else. This is
    an environment artifact, not a port bug — recorded here because it is
    exactly the kind of failure that looks like flakiness until traced.
11. `HttpProbe#response_for`'s `/flaky` branch read `@hits["/flaky"]`, an ivar
    that was never initialized anywhere in the class — the surrounding
    comment describes hit counts going through the log file instead, which
    is what `HttpProbe#hits` already does, but `response_for` itself was
    never updated to match. Every request to `/flaky` raised a silent
    `NoMethodError` inside the forked child, which `accept_loop`'s
    `rescue StandardError; nil` swallowed, closing the socket with no
    response ever written — "Connection terminated unexpectedly" on the
    client side, every time, not just on a flaky fraction of requests. This
    is why the retry-policy checks never actually exercised a retry. Fixed
    by counting `/flaky` hits off the log file, the same way `#hits` does.

## Known gap: there is no spec suite

The dev-shell banner names a spec command, but `spec/` holds only
`spec_helper.rb` and `README.md` — no `*_spec.rb` files at all. Running it:

    0 examples, 0 failures, 2 errors occurred outside of examples
    LoadError: cannot load such file -- kettle/test/rspec

`spec_helper.rb` is the untouched kettle-jem scaffold and requires
`kettle/test/rspec`, which the dev shell's `bundlerEnv` does not provide: the
flake builds its gems from `nix/Gemfile`, the gemspec's runtime dependencies
only, deliberately excluding the kettle-dev development stack. Nothing in the
port is currently covered by RSpec; the drive script covers it instead.

`bundle exec rubocop` fails for the same reason — rubocop is not in the
bundle. `rubocop` on its own, from the dev shell's tool wrapper, works and
reports no offences.
