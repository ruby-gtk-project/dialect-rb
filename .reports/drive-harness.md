# Driving the dialect port

`test/drive_dialect.rb` (plus `test/gtk_driver.rb`, copied unchanged from the
reference harness in `tally-rb`) builds the real application under Xvfb,
asserts every component the port claims, and writes screenshots to
`tmp/shots/`.

    nix develop --command xvfb-run -a ruby test/drive_dialect.rb

Last run: **330 of 330 checks passed — DRIVE OK**, 21 steps, 4 screenshots.

## What it covers

28 components, in two groups.

Widget components, driven through the live window (5): `Gtk::Application`,
`Adwaita::ApplicationWindow` (title, restored size, close-request persistence),
`Adwaita::ToolbarView`, `Adwaita::HeaderBar`, `Adwaita::StatusPage`.

Non-widget components, driven against real files and real sockets (23):
`Define`, `Utils`, the provider error hierarchy, `Languages`, `LangObject`,
`LanguagesListModel`, `Session`, `SessionHelpers`, `BackgroundTask`,
`Provider`, the four translation Data classes, `ProviderSettings`,
`Providers`, `ProviderObject`, `ProvidersListModel`, `Settings`, `Style`, and
each of the seven provider modules.

`Session` and `SessionHelpers` are driven against a loopback `TCPServer` the
script starts itself — redirects, form and JSON bodies, the User-Agent, the
retry policy and the error payload checks — so nothing touches the network.

## What it deliberately does not cover

The port's UI is still the scaffold. `.reports/component-inventory.md` lists
every upstream user-facing component as absent, and that is still true: there
is no translator window, preferences dialog, about dialog, app menu, lang
selector, speech button or theme switcher, and therefore no GAction and no
accelerator to fire. The last-but-one step asserts that absence explicitly —
all four `app.*` actions, all sixteen `win.*` actions and their accelerators —
so the harness cannot be mistaken for covering the upstream UI, and those
checks start failing the moment a component lands without being driven.

## Bug this found

The application never called `Adwaita.init`. Because
`Adwaita::Application` is broken in the Ruby bindings the port uses
`Gtk::Application`, which does not run `adw_init()` — so libadwaita's
stylesheet was never installed and every Adwaita widget rendered as an
unstyled GTK box (the status page icon came out 16px and its title in body
text). Fixed in `lib/dialect/application.rb`; `Adwaita.initialized?` is now a
check, and `tmp/shots/01-main-window.png` shows the styled result.

## Known gap: there is no spec suite

The dev-shell banner names a spec command, but `spec/` holds only
`spec_helper.rb` and `README.md` — no `*_spec.rb` files at all. Running it:

    0 examples, 0 failures, 2 errors occurred outside of examples
    LoadError: cannot load such file -- kettle/test/rspec

`spec_helper.rb` is the untouched kettle-jem scaffold and requires
`kettle/test/rspec`, which the dev shell's `bundlerEnv` does not provide: the
flake builds its gems from `nix/Gemfile`, the gemspec's runtime dependencies
only, deliberately excluding the kettle-dev development stack. Nothing in the
port is currently covered by RSpec; the display-free half is covered by the
drive script instead.
