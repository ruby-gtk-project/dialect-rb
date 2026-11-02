# Dialect — upstream component inventory

Survey of `origin/main` (Python + blueprint, libadwaita 1.7-era) against `lib/`
on the `ruby` branch. Produced with the `component-identification` skill;
widget/CSS/signal facets read off the `.blp`/`.ui` files, actions and
runtime-built widgets read off the Python.

**State of the port:** the non-widget half was ported first — settings,
languages, the build-time constants, the HTTP session, the async helper, the
stylesheet loader and all seven providers behind their base class, registry,
error types and per-provider settings (units 17–34). Round 1 of the UI then
landed units 1–10, 12–16 and 36: the application and its About dialog, the app
menu, the window with all four of its states and the whole translation view,
both language selectors and their rows, the theme switcher, the text views,
the preferences dialog and its provider subpage, the shortcuts window and the
two icon assets. The scaffold status page is gone;
`lib/dialect/application.rb` has been replaced by `lib/main.rb`.

**Still absent:** unit 11 (the speech button) and the `win.listen-src` /
`win.listen-dest` actions it drives, because there is no GStreamer typelib in
the dev shell to play a provider's audio with; unit 35 (the GNOME Shell search
provider); and unit 37 (the translation catalogs). Upstream's spell checking,
part of unit 4, is absent for the same reason as the speech button — no
Spelling typelib. Each is driven as absent by `test/drive_dialect.rb`, so none
of them can be mistaken for done.

House shape follows the pilot at `gnome-contacts-rb`: flat `lib/*.rb`, one
upstream unit per file, `# frozen_string_literal: true` + `require 'adwaita'` +
`require_relative` siblings, a comment naming the upstream file, memoized
widget accessors configured in `.tap`. The application class lands in
`lib/main.rb`, as the pilot does.

---

## Unit map

| # | Upstream file(s) | Target | Kind | Present |
|---|---|---|---:|---|
| 1 | `dialect/main.py` | `lib/main.rb` | application | **yes** |
| 2 | `dialect/main.py` (`_on_about`), `data/app.drey.Dialect.metainfo.xml.in.in` | `lib/main.rb` | dialog (About) | **yes** |
| 3 | `dialect/window.blp` (`menu app-menu`) | `lib/main_menu.rb` | menu model | **yes** |
| 4 | `dialect/window.blp`, `dialect/window.py` | `lib/window.rb` | window | **yes** (no spell checking — no Spelling typelib) |
| 5 | `dialect/window.blp` (`loading_page`) | `lib/window.rb` | loading state | **yes** |
| 6 | `dialect/window.blp` (`error_page`), `window.py` `show_translator_error_view` | `lib/window.rb` | error state | **yes** |
| 7 | `dialect/window.blp` (`key_page`), `window.py` `show_translator_api_key_view` | `lib/window.rb` | error state (API key) | **yes** |
| 8 | `dialect/window.blp` (`translator_box` + toolbars) | `lib/window.rb` | page (translation view) | **yes** (no speech buttons — see unit 11) |
| 9 | `dialect/widgets/lang_selector.blp`, `lang_selector.py` (`LangSelector`) | `lib/lang_selector.rb` | widget (popover selector) | **yes** |
| 10 | `dialect/widgets/lang_row.blp`, `lang_selector.py` (`LangRow`) | `lib/lang_row.rb` | row | **yes** |
| 11 | `dialect/widgets/speech_button.blp`, `speech_button.py` | `lib/speech_button.rb` | widget (button) | no (no Gst typelib to play the audio) |
| 12 | `dialect/widgets/theme_switcher.blp`, `theme_switcher.py` | `lib/theme_switcher.rb` | widget (menu custom slot) | **yes** |
| 13 | `dialect/widgets/textview.py` | `lib/text_view.rb` | widget (text view) | **yes** (on Gtk::TextView — no GtkSourceView typelib) |
| 14 | `dialect/preferences.ui`, `dialect/preferences.py` | `lib/preferences_dialog.rb` | preferences dialog | **yes** |
| 15 | `dialect/widgets/provider_preferences.blp`, `provider_preferences.py` | `lib/provider_preferences.rb` | preferences subpage | **yes** |
| 16 | `dialect/shortcuts.blp`, `dialect/shortcuts.py` | `lib/shortcuts_window.rb` | keyboard shortcuts | **yes** (Adw.ShortcutsDialog — Gtk::ShortcutsWindow cannot be constructed) |
| 17 | `dialect/settings.py`, `data/app.drey.Dialect.gschema.xml.in` | `lib/settings.rb` | settings/GSettings | **yes** |
| 18 | `dialect/languages.py` | `lib/languages.rb` | list model | **yes** |
| 19 | `dialect/define.in` (`LANGUAGES`, `LANG_ALIASES`, `TRANS_NUMBER`) | `lib/define.rb` | constants | **yes** |
| 20 | `dialect/providers/base.py`, `providers/local.py` | `lib/provider.rb` | provider base | **yes** |
| 21 | `dialect/providers/__init__.py` (`ProviderObject`, `ProvidersListModel`, registry) | `lib/providers.rb` | registry + list model | **yes** |
| 22 | `dialect/providers/errors.py` | `lib/provider_errors.rb` | error types | **yes** |
| 23 | `dialect/providers/settings.py` | `lib/provider_settings.rb` | per-provider settings + secrets | **yes** |
| 24 | `dialect/providers/modules/google.py` | `lib/google_provider.rb` | provider (translate + TTS) | **yes** |
| 25 | `dialect/providers/modules/bing.py` | `lib/bing_provider.rb` | provider | **yes** |
| 26 | `dialect/providers/modules/deepl.py` | `lib/deepl_provider.rb` | provider | **yes** |
| 27 | `dialect/providers/modules/kagi.py` | `lib/kagi_provider.rb` | provider | **yes** |
| 28 | `dialect/providers/modules/libretrans.py` | `lib/libretranslate_provider.rb` | provider | **yes** |
| 29 | `dialect/providers/modules/lingva.py` | `lib/lingva_provider.rb` | provider (translate + TTS) | **yes** |
| 30 | `dialect/providers/modules/yandex.py` | `lib/yandex_provider.rb` | provider | **yes** |
| 31 | `dialect/providers/soup.py`, `dialect/session.py` | `lib/session.rb` | HTTP session | **yes** |
| 32 | `dialect/asyncio.py` | `lib/background_task.rb` | async helper | **yes** |
| 33 | `dialect/utils.py` | `lib/utils.rb` | helpers | **yes** |
| 34 | `dialect/style.css`, `dialect/style-dark.css` | `lib/style.rb` | stylesheet loader | **yes** |
| 35 | `dialect/search_provider/search_provider.in` + `.ini`/`.service.in` | `lib/search_provider.rb` | GNOME Shell search provider | no |
| 36 | `dialect/icons/settings-symbolic.svg`, `icons/speakers-broken-symbolic.svg`, `dialect/dialect.gresource.xml` | `data/icons/` | icon assets | **yes** (`lib/icons.rb` adds them to the icon theme) |
| 37 | `po/` (git submodule, `dialect` + `dialect-cldr-langs` domains) | `po/` | translations | no (submodule not checked out) |

---

## 1 — `dialect/main.py` → `lib/main.rb` (the application)

`Adw.Application`, `HANDLES_COMMAND_LINE`, resource base path `/app/drey/Dialect`.
No widgets of its own; it owns the app actions, the accelerators, the About
dialog and the preferences entry point.

App actions:

| Action | Shape | Handler |
|---|---|---|
| `app.pronunciation` | stateful boolean, from `show-pronunciation` | toggles setting, calls `window._check_pronunciation` |
| `app.preferences` | simple | presents `DialectPreferencesDialog(window)` |
| `app.about` | simple | `Adw.AboutDialog.new_from_appdata` |
| `app.quit` | simple | `quit()` |

Accelerators installed here (window actions included):

`app.pronunciation <Primary>P` · `app.preferences <Primary>comma` ·
`app.quit <Primary>Q` · `win.back <Alt>Left` · `win.forward <Alt>Right` ·
`win.switch <Primary>S` · `win.from <Primary>F` · `win.to <Primary>T` ·
`win.clear <Primary>D` · `win.font-size-inc <Primary>plus`/`<Primary>KP_Add` ·
`win.font-size-dec <Primary>minus`/`<Primary>KP_Subtract` ·
`win.paste <Primary><Shift>V` · `win.copy <Primary><Shift>C` ·
`win.listen-dest <Primary>L` · `win.listen-src <Primary><Shift>L` ·
`win.show-help-overlay <Primary>question`

CLI options: `-n/--selection`, `-t/--text TEXT`, `-s/--src CODE`,
`-d/--dest CODE`; processed once the translator has finished loading
(`notify::translator-loading`).

## 2 — About dialog → `lib/main.rb`

`Adw.AboutDialog` built from the appdata: version, comments
("A translation app for GNOME."), copyright "Copyright 2020–2024 The Dialect
Authors", developers (Mufeed Ali, Rafael Mardojai CM, Libretto),
`translator_credits`, and an added link _Donate_ → `https://opencollective.com/dialect`.

## 3 — `menu app-menu` → `lib/main_menu.rb`

`Gio.Menu` with three sections, hung off `menu_btn`:

| Section | Items |
|---|---|
| (custom) | `custom: "theme"` → hosts `ThemeSwitcher` (added at runtime with `menu.add_child(theme_switcher, "theme")`) |
| `preferences-section` | _Show Pronunciation_ → `app.pronunciation` |
| `help-section` | _Preferences_ → `app.preferences`; _Keyboard Shortcuts_ → `win.show-help-overlay`; _About Dialect_ → `app.about` |

The `custom:` slot is a component boundary: the widget is built in `window.py`.

## 4 — `dialect/window.blp` + `window.py` → `lib/window.rb` (main window)

`Adw.ApplicationWindow`, default 800×300, min 360×320, `focus-widget: src_text`,
`notify::is-active => _on_is_active_changed`. Adds the `devel` CSS class when
`PROFILE == "Devel"`. `unrealize` saves window size and recent langs.

Top-level structure:

| Widget | × | CSS | Signals / notes |
|---|---:|---|---|
| `Adw.Breakpoint` | 1 | — | `max-width: 680px` → `multi_layout.layout-name = "mobile"`, `error_buttons`/`key_buttons` vertical, `mobile_buttons_size.mode = horizontal`, `translator_box` vertical |
| `Gtk.Stack main_stack` | 1 | — | crossfade; pages `loading`, `error`, `api-key`, `translate` |
| `Gtk.EventControllerKey win_key_ctrlr` | 1 | — | `key-pressed => _on_key_event` — any printable key types into `src_text` |
| `Gtk.SizeGroup` (unnamed) | 1 | — | mode `both`, over `src_lang_selector`, `dest_lang_selector` |
| `Gtk.SizeGroup mobile_buttons_size` | 1 | — | mode `none`, over `error_retry_btn`, `error_open_prefs_btn`, `rmv_key_btn`, `key_open_prefs_btn` |

Window actions (all `Gio.SimpleAction`, several starting disabled):

| Action | Enabled when | Handler |
|---|---|---|
| `win.back` | `current_history < len(history) - 1` | `_on_back_action` |
| `win.forward` | `current_history > 0` | `_on_forward_action` |
| `win.switch` | src ∈ dest langs and dest ∈ src langs | `_on_switch_action` |
| `win.from` / `win.to` | always | popup the matching `LangSelector` |
| `win.clear` | src text non-empty | `_on_clear_action` |
| `win.font-size-inc` / `win.font-size-dec` | always | `TextView#font_size_inc/dec` |
| `win.paste` | always | clipboard read → insert |
| `win.copy` | dest text non-empty | clipboard set + toast _Copied to clipboard_ (timeout 1) |
| `win.listen-src` / `win.listen-dest` | TTS lang supported, text non-empty, not loading, other side not playing | `_on_speech` |
| `win.suggest` | provider supports suggestions and dest non-empty | switches `dest_toolbar_stack` to `edit` |
| `win.suggest-ok` / `win.suggest-cancel` | always | submit / restore `before_suggest` |
| `win.translation` | src text non-empty | `_on_translation` |
| `win.show-help-overlay` | built-in | `set_help_overlay(DialectShortcutsWindow())` |

### 5 — loading state (`main_stack` page `loading`)

| Widget | × | CSS | Notes |
|---|---:|---|---|
| `Gtk.WindowHandle` | 1 | — | drag area while loading |
| `Adw.StatusPage loading_page` | 1 | — | `paintable: Adw.SpinnerPaintable { widget: loading_page }`, a11y label _Loading…_ |

### 6 — error state (`main_stack` page `error`)

| Widget | × | CSS | Signals |
|---|---:|---|---|
| `Adw.ToolbarView` + `Adw.HeaderBar` | 1 + 1 | — | — |
| `Adw.StatusPage error_page` | 1 | — | title/description set by `show_translator_error_view` |
| `Gtk.Box error_buttons` | 1 | — | spacing 12, centre; becomes vertical under the breakpoint |
| `Gtk.Button error_retry_btn` | 1 | `pill`, `suggested-action` | `clicked => _on_retry_load_translator_clicked` |
| `Gtk.Button error_open_prefs_btn` | 1 | `pill` | `action-name: app.preferences` |

Message variants, all translated: _Failed loading the translation service_ /
_Please report this in the Dialect bug tracker if the issue persists._;
_Unable to connect to the translation service._ /
_Unable to connect to the server. Please check for network issues._;
the instance-specific _Unable to connect to the {service} instance “{url}“…_
and _Failed loading “{url}“, check if the instance address is correct…_. The
raw exception is appended as `<small><tt>…</tt></small>`.

### 7 — API-key state (`main_stack` page `api-key`)

| Widget | × | CSS | Signals |
|---|---:|---|---|
| `Adw.ToolbarView` + `Adw.HeaderBar` | 1 + 1 | — | — |
| `Adw.StatusPage key_page` | 1 | — | `icon-name: dialog-password-symbolic` |
| `Gtk.Box key_buttons` | 1 | — | spacing 12, centre; vertical under the breakpoint |
| `Gtk.Button rmv_key_btn` | 1 | `pill`, `suggested-action` | hidden unless the key is merely invalid; `clicked => _on_remove_key_and_reload_clicked` |
| `Gtk.Button key_open_prefs_btn` | 1 | `pill` | `action-name: app.preferences` |

Titles: _API key is required to use the service_ / _Please set an API key in the
preferences._ and _The provided API key is invalid_ / _Please set a valid API
key in the preferences._ or _…or unset the API key in the preferences._

### 8 — translation view (`main_stack` page `translate`)

| Widget | × | CSS | Signals / notes |
|---|---:|---|---|
| `Adw.ToastOverlay toast_overlay` | 1 | — | all notifications; `Adw.Toast` built in `send_notification` (queue, action button, timeout, priority) |
| `Adw.MultiLayoutView multi_layout` | 1 | — | layouts `desktop` / `mobile` |
| `Adw.Layout` | 2 | — | desktop: header bar `centering-policy: strict`, selector as title widget; mobile: selector in a `[bottom]` slot with the `toolbar` class |
| `Adw.ToolbarView` | 2 | — | one per layout |
| `Adw.HeaderBar` | 2 | — | — |
| `Adw.LayoutSlot` | 8 | `toolbar` (mobile langs-selector only) | ids `langs-selector`, `back-btn`, `forward-btn`, `menu`, `translation` |
| `Gtk.MenuButton menu_btn` | 1 | — | `menu-model: app-menu`, primary, tooltip _Main Menu_; its popover receives the `theme` child |
| `Gtk.Button return_btn` | 1 | — | `win.back`, tooltip _Previous Translation_, `go-previous-symbolic` |
| `Gtk.Button forward_btn` | 1 | — | `win.forward`, tooltip _Next Translation_, `go-next-symbolic` |
| `Gtk.Box langs_button_box` | 1 | — | spacing 6; made insensitive during translation/switch |
| `LangSelector src_lang_selector` | 1 | — | `notify::selected => _on_src_lang_changed`, `user-selection-changed => _on_translation`, tooltip _Change Source Language_ |
| `Gtk.Button switch_btn` | 1 | — | `win.switch`, tooltip _Switch Languages_, `object-flip-horizontal-symbolic` |
| `LangSelector dest_lang_selector` | 1 | — | `notify::selected => _on_dest_lang_changed`, `user-selection-changed => _on_translation`, tooltip _Change Destination Language_ |
| `Gtk.Box translator_box` | 1 | `translation-box` (+ `.vertical` via CSS when the breakpoint flips it) | homogeneous, spacing 12 |
| `Gtk.Box` (src side) / `Gtk.Box dest_box` | 2 | `card`, `translation-side-box` | vertical, `overflow: hidden`; `dest_box` insensitive while translating |
| `Gtk.ScrolledWindow` | 4 | `translation-scrolled` (+ `top-undershoot` on the two pronunciation ones) | — |
| `TextView src_text` | 1 | `dialect-sourceview` (set in code) | margins 9; `activate => _on_src_activated`; buffer `changed`/`end-user-action` |
| `TextView dest_text` | 1 | `dialect-sourceview` | not editable except during suggest; font size bound bidirectionally to `src_text` |
| `Gtk.Revealer src_pron_revealer` / `dest_pron_revealer` | 2 | — | slide-down, hidden by default |
| `Gtk.Label src_pron_label` / `dest_pron_label` | 2 | `pronunciation`, `dim-label` | wrap word-char, selectable, `valign: end` |
| `Gtk.Revealer mistakes` | 1 | — | hidden by default |
| `Gtk.Box` (mistakes) | 1 | `card`, `mistakes` | spacing 8 |
| `Gtk.Image` (mistakes) | 1 | — | `error-correct-symbolic` |
| `Gtk.Label mistakes_label` | 1 | — | markup _Did you mean: `<a href="#">…</a>`_; `activate-link => _on_mistakes_clicked` |
| `Gtk.Box` (src toolbar) | 1 | `toolbar` | — |
| `Gtk.Button clear_btn` | 1 | — | `win.clear`, tooltip _Clear_, `edit-clear-symbolic` |
| `Gtk.Button paste_btn` | 1 | — | `win.paste`, tooltip _Paste_, `edit-paste-symbolic` |
| `SpeechButton src_speech_btn` | 1 | `flat`, `speech-button` | `win.listen-src`, tooltip _Listen_ |
| `Gtk.Label char_counter` | 1 | `dim-label`, `caption-heading`, `numeric` | `"{count}/{chars_limit}"`, empty when the limit is -1 |
| `Gtk.Button translate_btn` | 1 | `suggested-action` | label _Translate_, `win.translation` |
| `Gtk.Stack dest_toolbar_stack` | 1 | — | crossfade; pages `default`, `edit` |
| `Gtk.Box` (dest default toolbar) | 1 | `toolbar` | — |
| `Adw.Spinner trans_spinner` | 1 | — | tooltip _Translating…_, hidden except during a translation |
| `Gtk.Image trans_warning` | 1 | — | tooltip _Could not Translate the Text_, `dialog-warning-symbolic`, hidden unless the last translation failed |
| `Gtk.Button copy_btn` | 1 | — | `win.copy`, tooltip _Copy_, `edit-copy-symbolic` |
| `Gtk.Button edit_btn` | 1 | — | `win.suggest`, tooltip _Suggest Translation_, `document-edit-symbolic`; visible only when the provider supports suggestions |
| `SpeechButton dest_speech_btn` | 1 | `flat`, `speech-button` | `win.listen-dest`, tooltip _Listen_ |
| `Gtk.Box` (dest edit toolbar) | 1 | `toolbar` | — |
| `Gtk.Button cancel_btn` | 1 | — | `win.suggest-cancel`, label _Cancel_ |
| `Gtk.Button save_btn` | 1 | `suggested-action` | `win.suggest-ok`, label _Save_ |

Repeaters: none in the window itself (the lang lists are repeaters inside
`LangSelector`). Conditional: `rmv_key_btn`, `edit_btn`, both speech buttons
(hidden when TTS is disabled), `trans_spinner`, `trans_warning`, both
pronunciation revealers, the mistakes revealer.

Toast texts owned by the window: _Copied to clipboard_, _{n} characters limit
reached!_, _Unable to read the selected text._, _New translation has been
suggested!_, _Suggestion failed._, _Translation failed_ /
_Translation failed, check for network issues_ (with a _Retry_ button →
`win.translation`), _The provided API key is invalid_ (Retry),
_API key is required to use the service_ (button _Preferences_ →
`app.preferences`), _Text-to-Speech failed_ /
_…check for network issues_ (Retry → `win.listen-src`/`-dest`),
_Failed loading the text-to-speech service_ / _…check for network issues_.

Non-widget behaviour in this file that the port still owes: a 10-entry
translation history (`TRANS_NUMBER`) with back/forward, four-entry recent-lang
lists per direction, live translation, the `next_translation` coalescing of
in-flight requests, `_appeared_before` de-duplication, selection-clipboard
translation queued until the window is active, GStreamer `playbin` playback with
a tick-callback progress feed into the speech buttons, and libspelling
spell-checking on the source buffer with language picking from the source lang.

## 9 — `widgets/lang_selector.blp` + `lang_selector.py` → `lib/lang_selector.rb`

`Adw.Bin` subclass with a `selected` string property and a
`user-selection-changed` signal; `notify::selected => _on_selected_changed`.

| Widget | × | CSS | Signals / notes |
|---|---:|---|---|
| `Gtk.MenuButton button` | 1 | `raised` | `always-show-arrow`; `win.from`/`win.to` call `button.popup()` |
| `Gtk.Box` (button child) | 1 | — | spacing 3 |
| `Gtk.Label label` | 1 | — | ellipsize end; shows _Auto_ or the language name |
| `Gtk.Label insight` | 1 | — | `"(detected name)"` when src is Auto and `src_auto` is on |
| `Gtk.Popover popover` | 1 | `lang-selector`, `menu` | height 300; `show => _popover_show` (focus search), `closed => _popover_closed` (reset scroll, clear search) |
| `Gtk.Box search_box` | 1 | `search_box` | — |
| `Gtk.SearchEntry search` | 1 | — | placeholder _Search Languages…_; `changed => _on_search`, `activate => _on_search_activate`; `set_key_capture_widget(popover)`; extra `Gtk.EventControllerKey` → Esc closes, Down kept in the entry |
| `Gtk.ScrolledWindow scroll` | 1 | — | vexpand |
| `Gtk.Revealer revealer` | 1 | — | holds the recent list; hidden while a search is typed |
| `Gtk.ListBox recent_list` | 1 | — | `row-activated => _activated`; bound to the recent model |
| `Gtk.Separator separator` | 1 | — | — |
| `Gtk.ListBox lang_list` | 1 | — | `row-activated => _activated`; bound through `Gtk.SortListModel` (`CustomSorter`, name-case-insensitive) + `Gtk.FilterListModel` (`CustomFilter`, regex over the name) |
| `Gtk.EventControllerKey` | 1 | — | on the search entry |

Repeater: one `LangRow` per `LangObject` in each list — hundreds of rows from
`LANGUAGES`, plus up to five recents (Auto + four).

## 10 — `widgets/lang_row.blp` + `LangRow` → `lib/lang_row.rb`

| Widget | × | CSS | Notes |
|---|---:|---|---|
| `Gtk.ListBoxRow` | 1 | — | tooltip = language name |
| `Gtk.Box` | 1 | — | spacing 6 |
| `Gtk.Label name` | 1 | — | `xalign 0`, ellipsize end |
| `Gtk.Image selection` | 1 | — | `object-select-symbolic`, visible bound to `LangObject.selected` (`SYNC_CREATE`) |

## 11 — `widgets/speech_button.blp` + `speech_button.py` → `lib/speech_button.rb`

`Gtk.Button` subclass, class `speech-button`, tooltip _Listen_. Four states
driven by `ready()`, `progress(fraction)`, `error(message)`, `loading()`.

| Widget | × | CSS | Notes |
|---|---:|---|---|
| `Gtk.Overlay` | 1 | — | — |
| `Gtk.ProgressBar progress_bar` | 1 | `osd` | `valign: end`, shown only while playing |
| `Gtk.Stack stack` | 1 | — | pages `ready`, `progress`, `error`, `loading` |
| `Gtk.Image` | 3 | — | `audio-speakers-symbolic`, `media-playback-stop-symbolic`, `dialect-speakers-broken-symbolic` |
| `Adw.Spinner` | 1 | — | `loading` page |

Tooltips per state: _Listen_, _Cancel Audio_, the error message, _Loading…_.

## 12 — `widgets/theme_switcher.blp` + `theme_switcher.py` → `lib/theme_switcher.rb`

`Gtk.Box` subclass, class `themeswitcher`, lives in the menu's `theme` custom
slot. `show-system` bound from `Adw.StyleManager.system-supports-color-schemes`;
`color-scheme` two-way bound to GSettings.

| Widget | × | CSS | Signals |
|---|---:|---|---|
| `Gtk.Box box` | 1 | — | horizontal, spacing 12 |
| `Gtk.CheckButton system` | 1 | `theme-selector`, `system` | `notify::active => _on_color_scheme_changed`; tooltip _Follow System Style_; visible bound to `show-system` |
| `Gtk.CheckButton light` | 1 | `theme-selector`, `light` | grouped with `system`; tooltip _Light Style_ |
| `Gtk.CheckButton dark` | 1 | `theme-selector`, `dark` | grouped with `system`; tooltip _Dark Style_ |

The gradient/colour swatches are entirely CSS (`.themeswitcher checkbutton.*`
in `style.css`) — copying the widgets without that block gives three plain radios.

## 13 — `widgets/textview.py` → `lib/text_view.rb`

`GtkSource.View` subclass, CSS class `dialect-sourceview`, word-char wrapping,
an `activate` signal and an `activate_mod` property, a `font-size` property
backed by a per-widget `Gtk.CssProvider` (`textview { font-size: Npt; }`),
`font_size_inc` (+5) / `font_size_dec` (−5, floor 6).

| Controller | Behaviour |
|---|---|
| `Gtk.EventControllerKey` | Ctrl+Return / Ctrl+KP_Enter emits `activate` when `activate_mod`; bare Return when not |
| `Gtk.EventControllerScroll` (VERTICAL) | Ctrl+scroll changes the font size |

## 14 — `preferences.ui` + `preferences.py` → `lib/preferences_dialog.rb`

`Adw.PreferencesDialog`, one `Adw.PreferencesPage`, three groups.

| Group | Widget | × | CSS | Signals / binding |
|---|---|---:|---|---|
| Providers | `Adw.ComboRow translator` | 1 | — | title _Translator_, subtitle _Choose from the available translation services._, expression `prettyname`; `notify::selected => _switch_translator`; insensitive while the translator loads |
| | `Gtk.Separator` | 2 | — | one per combo row, margins 12 |
| | `Gtk.Button translator_config` | 1 | `flat` | `dialect-settings-symbolic`; `notify::sensitive => _provider_settings_tooltip`; `clicked` pushes `ProviderPreferences("trans")` |
| | `Adw.ComboRow tts` | 1 | — | title _Text-to-Speech_, subtitle _Choose from the available TTS services._; `notify::selected => _switch_tts`; hidden when no TTS provider exists |
| | `Gtk.Button tts_config` | 1 | `flat` | as above, scope `tts` |
| Behavior | `Adw.ExpanderRow live_translation` | 1 | — | _Live Translation_ / _Warning: Your IP address may get banned for API abuse._; enable-switch bound to `live-translation` |
| | `Adw.SwitchRow search_provider` | 1 | — | _Show Translations in Desktop Search_ / _Warning: All desktop searches will be sent to the translation service_; bound to `sp-translation`; hidden off GNOME |
| | `Adw.ComboRow translate_accel` | 1 | — | _Translation Shortcut_ / _The unselected choice will be used for line break._; `Gtk.StringList` ["Ctrl + Enter", "Enter"]; `sensitive` bound through the `is_not_true` closure on `live_translation.enable-expansion` |
| | `Adw.SwitchRow src_auto` | 1 | — | _Default to Auto_ / _Use "Auto" as the default language_; bound to `src-auto` |
| Appearance | `Adw.ExpanderRow custom_default_font_size` | 1 | — | _Use Custom Font Size_ / _System font size is used otherwise._; bound to `custom-default-font-size`; `notify::enable-expansion` seeds the system size the first time |
| | `Adw.SpinRow default_font_size` | 1 | — | _Default Font Size_ / _Changing the size via shortcuts does not overwrite this._; `Gtk.Adjustment` 6–72, step 5, page 10; `value-changed` → setting + `window.set_font_size` |

Tooltips on the config buttons: _Edit Provider Settings_ /
_No Settings for This Provider_. `ProvidersListModel` supplies both combo
models; the TTS model gets a leading _Disabled_ entry.

## 15 — `widgets/provider_preferences.blp` + `.py` → `lib/provider_preferences.rb`

`Adw.NavigationPage` titled _Provider Preferences_, pushed as a subpage of the
preferences dialog. Properties `translation`, `tts`, `definitions` from the
provider's capabilities.

| Widget | × | CSS | Signals / notes |
|---|---:|---|---|
| `Adw.ToolbarView` + `Adw.HeaderBar` | 1 + 1 | — | — |
| `Adw.WindowTitle title` | 1 | — | title _Provider Preferences_, subtitle = provider prettyname |
| `Adw.PreferencesPage page` | 1 | — | insensitive while the translator loads |
| `Adw.PreferencesGroup instance_group` | 1 | — | — |
| `Adw.EntryRow instance_entry` | 1 | `error` (dynamic, on failed validation) | _Instance URL_, tooltip _Enter an Instance URL for the Provider._, show-apply-button; `apply => _on_instance_apply`, `notify::text => _on_instance_changed`; visible only when the provider supports instances |
| `Gtk.Stack instance_stack` | 1 | — | pages `reset`, `spinner` |
| `Gtk.Button instance_reset` | 1 | `flat` | `view-refresh-symbolic`, tooltip _Reset to Default_, `clicked => _on_reset_instance` |
| `Adw.PasswordEntryRow api_key_entry` | 1 | `error` (dynamic) | _API Key_, tooltip _Enter an API Key for the Provider._, show-apply-button; `apply => _on_api_key_apply`; visible only when the provider supports API keys |
| `Gtk.Stack api_key_stack` | 1 | — | pages `reset`, `spinner` |
| `Gtk.Button api_key_reset` | 1 | `flat` | `view-refresh-symbolic`, `clicked => _on_reset_api_key` |
| `Adw.Spinner` | 2 | — | the two `spinner` stack pages |
| `Adw.PreferencesGroup api_usage_group` | 1 | — | _Character Usage_, hidden unless the provider reports usage |
| `Gtk.Box` | 1 | — | vertical, spacing 3 |
| `Gtk.LevelBar api_usage` | 1 | — | value = usage/limit |
| `Gtk.Label api_usage_label` | 1 | — | _{usage:n} of {limit:n} characters_ |

Toasts raised on the parent dialog: _Not a valid {provider} instance_,
_Failed validating instance, check for network issues_,
_Not a valid {provider} API key_,
_Failed validating API key, check for network issues_.

## 16 — `shortcuts.blp` + `shortcuts.py` → `lib/shortcuts_window.rb`

`Gtk.ShortcutsWindow`, modal, one section (`max-height: 10`), installed as the
window's help overlay. `show => _on_show` hides the _Translate_ shortcut when
live translation is on and sets its accelerator from `translate-accel`.

| Group | Shortcuts |
|---|---|
| Translator | Translate (`<Primary>Return`, dynamic), Switch Languages, Select source language, Select destination language, Clear source text, Copy translation, Show Pronunciation, Increase font size, Decrease font size |
| Text-to-Speech | Listen to source text, Listen to translation |
| Navigation | Go back in history, Go forward in history |
| General | Preferences, Shortcuts, Quit |

All titles use the `shortcuts window` gettext context (one, _Shortcuts_, uses
`shortcut window` — an upstream typo worth keeping an eye on when the catalogue
lands). Every entry but _Translate_ is declared by `action-name`, so the
accelerator comes from the app's `set_accels_for_action` table.

Binding note: `Gtk::ShortcutsWindow`/`Section`/`Group`/`Shortcut` all exist in
the Ruby bindings, and `Adwaita::ShortcutsDialog` is available too (the pilot
uses it); the port should pick one and record the choice.

## 17 — `settings.py` + `data/app.drey.Dialect.gschema.xml.in` → `lib/settings.rb`

Main schema (path `/app/drey/Dialect/`): `window-size ai [800,300]`,
`color-scheme s` (auto|light|dark, default auto), `live-translation b false`,
`sp-translation b false`, `show-pronunciation b false`, `src-auto b true`,
`translate-accel i 0` (0 = Ctrl+Enter, 1 = Enter),
`custom-default-font-size b false`, `default-font-size i 0`; children `tts` and
`translators`. `SettingsList` (`list as`, `active s`) is extended by
`TranslatorsList` (active `"google"`) and `TTSList` (active `"google"`). The
per-translator schema (`…​.translator`, path
`/app/drey/Dialect/translators/<name>/`) holds `init b`, `src-langs as`,
`dest-langs as`, `instance-url s`, `api-key s`.

Behaviour: a `provider-changed` detailed signal (`::translator`, `::tts`) that
the window listens to in order to reload providers, fallback to the first
available translator when the stored one vanished, and `system_font_size` read
off `gtk-font-name`.

## 18 — `languages.py` → `lib/languages.rb`

`LangObject` (`code`, `name`, `selected`) and `LanguagesListModel`
(`Gio.ListModel`) with `set_langs(langs, auto=False)` — prepends an _Auto_
entry — and `set_selected(code)`. Four instances in the window: src, src-recent,
dest, dest-recent. Language names are translated with the code as gettext
context (`pgettext(code, name)`), from the `dialect-cldr-langs` catalogue.

## 19 — `define.in` → `lib/define.rb`

`APP_ID`, `PROFILE`, `RES_PATH`, `VERSION`, `TRANS_NUMBER = 10`,
`LANG_ALIASES` (5 entries) and `LANGUAGES` — the ~600-entry code→English-name
table that every selector row is built from. Not a widget, but no language list
renders without it.

## 20–23 — provider framework

| Upstream | Target | Contents |
|---|---|---|
| `providers/base.py` (+ `local.py`) | `lib/provider.rb` | `ProviderCapability` (TRANSLATION/TTS/DEFINITIONS), `ProviderFeature` (INSTANCES, API_KEY, API_KEY_REQUIRED, API_KEY_USAGE, DETECTION, MISTAKES, PRONUNCIATION, SUGGESTIONS), `ProviderLangModel` (STATIC/DYNAMIC), `ProviderLangComparison` (PLAIN/DEEP), the `TranslationRequest` / `Translation` / `TranslationMistake` / `TranslationPronunciation` records, `chars_limit`, `cmp_langs`, `normalize_lang_code` |
| `providers/__init__.py` | `lib/providers.rb` | the `MODULES`/`TRANSLATORS`/`TTS` registries, `check_translator_availability`, `get_fallback_translator_name`, and `ProviderObject` / `ProvidersListModel` (the models behind both preference combo rows, including the _Disabled_ entry) |
| `providers/errors.py` | `lib/provider_errors.rb` | `RequestError`, `ProviderError`, `UnexpectedError`, `APIKeyRequired`, `APIKeyInvalid`, `InvalidLangCode`, `BatchSizeExceeded`, `CharactersLimitExceeded`, `ServiceLimitReached` — each one maps to a distinct user-visible state |
| `providers/settings.py` | `lib/provider_settings.rb` | per-provider `Gio.Settings` plus API keys in libsecret (with migration out of GSettings), recent src/dest langs |

## 24–30 — provider modules

| Provider | `name` / `prettyname` | Capabilities | Features |
|---|---|---|---|
| `google.py` | google / Google | translation + TTS | detection, mistakes, pronunciation |
| `bing.py` | bing / Bing | translation | detection, pronunciation |
| `deepl.py` | deepl / DeepL | translation | API key (required), usage; DEEP lang comparison |
| `kagi.py` | kagi / Kagi Translate | translation | detection, API key required; DEEP |
| `libretrans.py` | libretranslate / LibreTranslate | translation | instances, detection |
| `lingva.py` | lingva / Lingva Translate | translation + TTS | instances, detection, pronunciation |
| `yandex.py` | yandex / Yandex | translation | detection; DEEP |

Which of these the port ships decides which preference rows and which error
states are reachable, so the choice belongs in `PLAN.md` rather than being made
file by file.

## 31–34 — support

* `providers/soup.py` + `session.py` → `lib/session.rb`: the shared
  `Soup.Session`, async `send_and_read`, and `ResponseError`.
* `asyncio.py` → `lib/background_task.rb`: the `background_task` decorator every
  async signal handler uses.
* `utils.py` → `lib/utils.rb`: `find_item_match`, `first_exclude` — both used by
  the lang-swap logic.
* `style.css` (+ empty `style-dark.css`) → `lib/style.rb`: 11 rule blocks
  defining `translation-box`, `translation-side-box`, `translation-scrolled`,
  `top-undershoot`, `mistakes`, `pronunciation`, `search_box`, `lang-selector`,
  `themeswitcher` (+ `theme-selector`/`system`/`light`/`dark`),
  `speech-button`, `dialect-sourceview`. Every one of these is applied by a
  component above; none is dead.

## 35 — GNOME Shell search provider → `lib/search_provider.rb`

`org.gnome.Shell.SearchProvider2` on the bus name `app.drey.Dialect.SearchProvider`:
`GetInitialResultSet`, `GetSubsearchResultSet`, `GetResultMetas`,
`ActivateResult`, `LaunchSearch`. Result ids are prefixed
`copy-to-clipboard` / `translation-error`. Gated by the `sp-translation`
setting and the _Show Translations in Desktop Search_ switch row.

## 36 — icons

`dialect-settings-symbolic` (the provider config buttons) and
`dialect-speakers-broken-symbolic` (the speech button's error page) are app
icons shipped through GResource. Without them two components render a
missing-image placeholder, so they are part of the port, not decoration.

## 37 — translations

`po/` is a git submodule (`https://github.com/dialect-app/po`, pinned at
`366f2ad`) and is **not checked out** in this clone. Two gettext domains:
`dialect` (UI strings) and `dialect-cldr-langs` (language names, looked up with
the language code as msgctxt).

---

## Totals

* 37 units; 18 present in `lib/` (17–34, the non-widget layer), 19 absent
  (1–16 every user-facing component, plus 35–37).
* 4 top-level states in one `Gtk.Stack` (loading / error / api-key / translate),
  2 layouts behind one `Adw.Breakpoint`.
* 20 window actions + 4 app actions; 16 accelerator bindings.
* 2 dialogs (preferences, about) + 1 pushed navigation subpage + 1 shortcuts window.
* 5 custom widget classes (`LangSelector`, `LangRow`, `SpeechButton`,
  `ThemeSwitcher`, `TextView`).
* 25 distinct CSS classes in play, 11 of them defined by the app's own stylesheet.
* 7 provider modules behind one base class and 9 error types.

## Blockers for the port

1. **`po/` is not checked out.** Translation parity cannot be assessed, let
   alone reproduced, until the submodule is fetched.
2. **No GtkSourceView in the dev shell** (`require "gtksourceview5"` fails).
   `TextView` subclasses `GtkSource.View` upstream; the port has to either add
   the dependency or build on `Gtk::TextView` and record the downgrade.
3. **No GStreamer in the dev shell** (`require "gst"` fails). Text-to-speech
   playback, the progress feed into `SpeechButton`, and `win.listen-src` /
   `win.listen-dest` have no audio path.
4. **No libspelling binding.** The source-buffer spell checking, its extra
   context menu and the language-picking logic in `window.py` have no
   equivalent.
5. **No libsecret binding.** API keys are stored in the secret service
   upstream; the port needs another store, which changes what
   `ProviderPreferences` can promise.
6. ~~**No libsoup binding**~~ — resolved: `lib/session.rb` rewrites
   `soup.py`/`session.py` on Ruby's own HTTP stack, keeping the
   `Session.get`/`post` shape the providers call.
7. **Provider scope is undecided.** Seven network providers, several needing
   API keys, cannot all be exercised; which ones ship decides which
   preference rows and error states are even reachable.
8. **No `PLAN.md` yet**, so there is no unit ordering for the port to follow;
   this inventory is the input to writing one. With 17–34 landed, the next
   unit has to be a widget one — `lib/window.rb` (unit 4) and its four stack
   states are what every other UI unit hangs off.

Dev shell confirms the widget side is available: GTK 4.22.4 with
`Adwaita::MultiLayoutView`, `Layout`, `LayoutSlot`, `Breakpoint`, `Spinner`,
`SpinnerPaintable`, `ToastOverlay`, `ShortcutsDialog`, `PreferencesDialog`,
`NavigationPage`, `EntryRow`, `PasswordEntryRow`, `SpinRow`, `ComboRow`,
`ExpanderRow`, `SwitchRow`, `WindowTitle` all present, and
`Gtk::ShortcutsWindow`, `CustomFilter`, `CustomSorter`, `SortListModel`,
`FilterListModel`, `StringList`, `LevelBar`, `WindowHandle`, `SizeGroup` too.
