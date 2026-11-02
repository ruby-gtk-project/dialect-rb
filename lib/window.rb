# frozen_string_literal: true

require 'gtk4'
require 'adwaita'

require_relative 'background_task'
require_relative 'define'
require_relative 'lang_selector'
require_relative 'languages'
require_relative 'main_menu'
require_relative 'provider_errors'
require_relative 'providers'
require_relative 'settings'
require_relative 'shortcuts_window'
require_relative 'text_view'
require_relative 'theme_switcher'
require_relative 'utils'

# The translator window: the loading, error, API-key and translation states,
# the two language selectors, the source and destination text views, the
# history, the suggestion editor and the window's own actions.
#
# Ported from upstream's dialect/window.blp and dialect/window.py.
#
# Shape. Upstream's window is one Gtk.Stack with four pages — loading, error,
# api-key and translate — and the translate page is an Adw.MultiLayoutView
# holding a desktop and a mobile layout over one set of slotted widgets, so
# the same menu button, nav buttons, language selectors and translation box
# are re-parented rather than built twice. All of that is carried over as it
# stands; the Ruby bindings have MultiLayoutView, Layout and LayoutSlot, and
# they behave as the C API does.
#
# Four deliberate departures, each forced by what this machine's bindings
# ship, and each one named in the port's notes rather than papered over:
#
# * Text-to-speech is left out. Upstream plays the provider's audio through a
#   GStreamer playbin, and there is no Gst typelib in the dev shell, so there
#   is nothing to play it with. The speech buttons, the `listen-src` and
#   `listen-dest` actions and the Text-to-Speech shortcuts group go with it:
#   a button wired to an action that cannot work is worse than no button.
# * Spell checking is left out, for the same reason — no Spelling typelib —
#   so upstream's setup_spell_checking and _pick_spell_checking_language have
#   nothing to configure.
# * Upstream declares `translator-loading` as a GObject property that the
#   application and both preferences pages watch with notify::. A plain class
#   has no bindable properties, so observers register blocks through
#   #on_translator_loading instead.
# * Upstream's breakpoint uses Adw.Breakpoint setters. add_setter is unusable
#   from Ruby for anything but a string value — it is handed an unboxed value
#   and fails g_object_ref — so the same five changes are made in the
#   breakpoint's apply and unapply handlers, which is what the setters compile
#   to anyway.
class Window
  # Upstream's two StackPage names for the states that are not a translation.
  LOADING_PAGE = 'loading'
  ERROR_PAGE = 'error'
  KEY_PAGE = 'api-key'
  TRANSLATE_PAGE = 'translate'

  DESKTOP_LAYOUT = 'desktop'
  MOBILE_LAYOUT = 'mobile'

  # The window's actions, and whether each starts enabled, mirroring
  # upstream's setup_actions.
  ACTIONS = {
    'back'              => false,
    'forward'           => false,
    'switch'            => true,
    'from'              => true,
    'to'                => true,
    'clear'             => false,
    'font-size-inc'     => true,
    'font-size-dec'     => true,
    'paste'             => true,
    'copy'              => false,
    'suggest'           => false,
    'suggest-ok'        => true,
    'suggest-cancel'    => true,
    'translation'       => false,
    'show-help-overlay' => true,
  }.freeze

  # The error view's default title and description, upstream's defaults for
  # show_translator_error_view.
  ERROR_TITLE = 'Failed loading the translation service'
  ERROR_DESCRIPTION = 'Please report this in the Dialect bug tracker if the issue persists.'

  # How many languages upstream keeps in each recent list.
  RECENT_LANGS = 4

  attr_reader :app, :settings

  def initialize(app, settings: Settings.get)
    @app = app
    @settings = settings
    @provider = { 'trans' => nil, 'tts' => nil }
    @src_langs = []
    @dest_langs = []
    @current_history = 0
    @translator_loading = true
    @translation_loading = false
    @next_translation = nil
    @before_suggest = nil
    @selection_translation_queued = false
    @selection_translation_langs = [nil, nil]
    @loading_observers = []
  end

  def build
    tap do
      setup_actions

      window.tap do |win|
        win.content = main_stack
        win.add_breakpoint(breakpoint)
        win.add_controller(key_controller)

        if Define::PROFILE == 'Devel'
          win.add_css_class('devel')
        end

        win.signal_connect('close-request') do
          save_settings
          false
        end

        win.signal_connect('notify::is-active') { on_is_active_changed }

        key_controller.signal_connect('key-pressed') do |_controller, keyval, _keycode, state|
          on_key_event(keyval, state)
        end
      end

      main_stack.tap do |stack|
        stack.add_named(loading_handle, LOADING_PAGE)
        stack.add_named(error_toolbar, ERROR_PAGE)
        stack.add_named(key_toolbar, KEY_PAGE)
        stack.add_named(toast_overlay, TRANSLATE_PAGE)
        stack.visible_child_name = LOADING_PAGE
      end

      build_loading_page
      build_error_page
      build_key_page
      build_translate_page
      build_breakpoint

      setup_selectors
      setup_translation

      # Upstream's window listens for the user switching the active provider
      # in the preferences dialog.
      settings.on_provider_changed do |kind, _name|
        save_settings
        reload_provider(kind)
      end

      load_translator
    end
  end

  def present = window.present

  # --- what the application and the preferences pages ask of the window ---

  def translator_loading? = @translator_loading

  # Registers an observer for upstream's notify::translator-loading.
  def on_translator_loading(&block)
    @loading_observers << block
    block
  end

  # The live provider object for a scope, upstream's `window.provider[scope]`.
  def provider(scope) = @provider[scope]

  def set_font_size(size)
    src_text.font_size = size
  end

  # Re-reads the translation shortcut the user picked. Upstream watches
  # Settings' changed::translate-accel; the port's Settings is a plain object
  # with no change signal, so the preferences dialog calls this.
  def apply_translate_accel
    src_text.activate_mod = settings.translate_accel_value.zero?
  end

  def reload_provider(kind)
    case kind
    when 'translator' then load_translator
    when 'tts' then nil
    end
  end

  # Translates the given text, switching to the languages asked for, which is
  # how the search provider and the command line reach the window.
  def translate(text, src_lang, dest_lang)
    with_trans do |trans|
      if src_lang.nil?
        if trans.supports_detection?
          src_lang_selector.selected = LangSelector::AUTO_CODE
        else
          src_lang_selector.selected = trans.recent_src_langs.first.to_s
        end
      else
        src_lang_selector.selected = src_lang
      end

      if !dest_lang.nil? && trans.dest_languages.include?(dest_lang)
        dest_lang_selector.selected = dest_lang
      end

      src_text.text = text
      run_translation
    end
  end

  # Translates the primary selection, or waits until the window is focused
  # before doing it, upstream's queue_selection_translation.
  def queue_selection_translation(src_lang, dest_lang)
    if window.is_active?
      translate_selection(src_lang, dest_lang)
    else
      @selection_translation_queued = true
      @selection_translation_langs = [src_lang, dest_lang]
    end
  end

  def save_settings
    unless window.maximized?
      settings.window_size = [window.default_width, window.default_height]
    end

    with_trans do |trans|
      trans.recent_src_langs = @src_langs
      trans.recent_dest_langs = @dest_langs
    end
  end

  # Shows an in-app notification, upstream's send_notification.
  def send_notification(text, queue: false, action: nil, timeout: 5, priority: :normal)
    unless queue || @toast.nil?
      @toast.dismiss
    end

    Adwaita::Toast.new(text).tap do |toast|
      @toast = toast
      toast.timeout = timeout
      toast.priority = priority
      toast.signal_connect('dismissed') { @toast = nil }

      if action
        toast.button_label = action[:label]
        toast.action_name = action[:name]
      end

      toast_overlay.add_toast(toast)
    end
  end

  # Reveals or hides the two pronunciation rows, and enables the menu's
  # pronunciation toggle only for a provider that reports pronunciations. The
  # application's `pronunciation` action calls this when it is toggled.
  def check_pronunciation
    with_trans do |trans|
      if trans.supports_pronunciation?
        app.lookup_action('pronunciation')&.enabled = true
        settings.show_pronunciation.then { |reveal| reveal_pronunciations(reveal) }
      else
        app.lookup_action('pronunciation')&.enabled = false
        src_pron_revealer.reveal_child = false
        dest_pron_revealer.reveal_child = false
      end
    end
  end

  # --- state views --------------------------------------------------------

  # Upstream's show_translator_error_view.
  def show_translator_error_view(title: ERROR_TITLE, description: ERROR_DESCRIPTION, detail: nil)
    error_page.tap do |page|
      page.title = title
      page.description = error_description(description, detail)
    end

    main_stack.visible_child_name = ERROR_PAGE
  end

  # Upstream's show_translator_api_key_view.
  def show_translator_api_key_view(required: false)
    with_trans do |trans|
      if required
        key_page.title = 'API key is required to use the service'
        key_page.description = 'Please set an API key in the preferences.'
      elsif trans.api_key_required?
        key_page.title = 'The provided API key is invalid'
        key_page.description = 'Please set a valid API key in the preferences.'
      else
        key_page.title = 'The provided API key is invalid'
        key_page.description = 'Please set a valid API key or unset the API key in the preferences.'
        rmv_key_btn.visible = true
      end

      main_stack.visible_child_name = KEY_PAGE
    end
  end

  # --- memoized widget methods -------------------------------------------

  def window
    @window ||= Adwaita::ApplicationWindow.new(app).tap do |win|
      win.title = 'Dialect'
      win.set_default_size(*settings.window_size)
      win.width_request = 360
      win.height_request = 320
    end
  end

  def key_controller = @key_controller ||= Gtk::EventControllerKey.new

  def main_stack
    @main_stack ||= Gtk::Stack.new.tap do |stack|
      stack.transition_type = :crossfade
    end
  end

  # Loading state

  def loading_handle = @loading_handle ||= Gtk::WindowHandle.new

  def loading_page
    @loading_page ||= Adwaita::StatusPage.new.tap do |page|
      page.title = 'Loading…'
    end
  end

  # Error state

  def error_toolbar = @error_toolbar ||= Adwaita::ToolbarView.new
  def error_header = @error_header ||= Adwaita::HeaderBar.new

  def error_page
    @error_page ||= Adwaita::StatusPage.new.tap do |page|
      page.vexpand = true
      page.title = ERROR_TITLE
      page.description = ERROR_DESCRIPTION
    end
  end

  def error_buttons
    @error_buttons ||= Gtk::Box.new(:horizontal, 12).tap do |box|
      box.halign = :center
    end
  end

  def error_retry_btn = @error_retry_btn ||= pill_button('Retry', suggested: true)
  def error_open_prefs_btn = @error_open_prefs_btn ||= pill_button('Open Preferences')

  # API key state

  def key_toolbar = @key_toolbar ||= Adwaita::ToolbarView.new
  def key_header = @key_header ||= Adwaita::HeaderBar.new

  def key_page
    @key_page ||= Adwaita::StatusPage.new.tap do |page|
      page.vexpand = true
      page.icon_name = 'dialog-password-symbolic'
    end
  end

  def key_buttons
    @key_buttons ||= Gtk::Box.new(:horizontal, 12).tap do |box|
      box.halign = :center
    end
  end

  def rmv_key_btn
    @rmv_key_btn ||= pill_button('Remove Key and Retry', suggested: true).tap do |button|
      button.visible = false
    end
  end

  def key_open_prefs_btn = @key_open_prefs_btn ||= pill_button('Open Preferences')

  # The size group upstream's breakpoint flips to horizontal on a narrow
  # window, so the stacked error buttons come out the same width.
  def mobile_buttons_size
    @mobile_buttons_size ||= Gtk::SizeGroup.new(:none).tap do |group|
      group.add_widget(error_retry_btn)
      group.add_widget(error_open_prefs_btn)
      group.add_widget(rmv_key_btn)
      group.add_widget(key_open_prefs_btn)
    end
  end

  # Translation state

  def toast_overlay
    @toast_overlay ||= Adwaita::ToastOverlay.new.tap do |overlay|
      overlay.vexpand = true
    end
  end

  def multi_layout = @multi_layout ||= Adwaita::MultiLayoutView.new

  def desktop_layout
    @desktop_layout ||= Adwaita::Layout.new(desktop_toolbar).tap do |layout|
      layout.name = DESKTOP_LAYOUT
    end
  end

  def mobile_layout
    @mobile_layout ||= Adwaita::Layout.new(mobile_toolbar).tap do |layout|
      layout.name = MOBILE_LAYOUT
    end
  end

  def desktop_toolbar = @desktop_toolbar ||= Adwaita::ToolbarView.new

  def desktop_header
    @desktop_header ||= Adwaita::HeaderBar.new.tap do |header|
      header.centering_policy = :strict
    end
  end

  def mobile_toolbar = @mobile_toolbar ||= Adwaita::ToolbarView.new
  def mobile_header = @mobile_header ||= Adwaita::HeaderBar.new

  # Each layout needs its own slot widgets; a slot is a real widget and
  # cannot be in two layouts at once.
  def desktop_langs_slot = @desktop_langs_slot ||= Adwaita::LayoutSlot.new('langs-selector')
  def desktop_back_slot = @desktop_back_slot ||= Adwaita::LayoutSlot.new('back-btn')
  def desktop_forward_slot = @desktop_forward_slot ||= Adwaita::LayoutSlot.new('forward-btn')
  def desktop_menu_slot = @desktop_menu_slot ||= Adwaita::LayoutSlot.new('menu')
  def desktop_translation_slot = @desktop_translation_slot ||= Adwaita::LayoutSlot.new('translation')

  def mobile_back_slot = @mobile_back_slot ||= Adwaita::LayoutSlot.new('back-btn')
  def mobile_forward_slot = @mobile_forward_slot ||= Adwaita::LayoutSlot.new('forward-btn')
  def mobile_menu_slot = @mobile_menu_slot ||= Adwaita::LayoutSlot.new('menu')
  def mobile_translation_slot = @mobile_translation_slot ||= Adwaita::LayoutSlot.new('translation')

  def mobile_langs_slot
    @mobile_langs_slot ||= Adwaita::LayoutSlot.new('langs-selector').tap do |slot|
      slot.halign = :center
      slot.add_css_class('toolbar')
    end
  end

  # Slotted widgets

  def main_menu = @main_menu ||= MainMenu.new

  def menu_btn
    @menu_btn ||= Gtk::MenuButton.new.tap do |button|
      button.tooltip_text = 'Main Menu'
      button.icon_name = 'open-menu-symbolic'
      button.primary = true
      button.menu_model = main_menu.build
    end
  end

  def theme_switcher = @theme_switcher ||= ThemeSwitcher.new(settings: settings)

  def return_btn = @return_btn ||= action_button('win.back', 'Previous Translation', 'go-previous-symbolic')
  def forward_btn = @forward_btn ||= action_button('win.forward', 'Next Translation', 'go-next-symbolic')

  def langs_button_box = @langs_button_box ||= Gtk::Box.new(:horizontal, 6)

  def src_lang_selector
    @src_lang_selector ||= LangSelector.new(
      tooltip:                   'Change Source Language',
      on_selected_changed:       ->(_code) { on_src_lang_changed },
      on_user_selection_changed: ->(_code) { run_translation },
    )
  end

  def dest_lang_selector
    @dest_lang_selector ||= LangSelector.new(
      tooltip:                   'Change Destination Language',
      on_selected_changed:       ->(_code) { on_dest_lang_changed },
      on_user_selection_changed: ->(_code) { run_translation },
    )
  end

  def switch_btn = @switch_btn ||= action_button('win.switch', 'Switch Languages', 'object-flip-horizontal-symbolic')

  def langs_size_group
    @langs_size_group ||= Gtk::SizeGroup.new(:both).tap do |group|
      group.add_widget(src_lang_selector)
      group.add_widget(dest_lang_selector)
    end
  end

  def translator_box
    @translator_box ||= Gtk::Box.new(:horizontal, 12).tap do |box|
      box.vexpand = true
      box.homogeneous = true
      box.add_css_class('translation-box')
    end
  end

  # Source side

  def src_box = @src_box ||= side_box
  def src_scroll = @src_scroll ||= translation_scroll

  def src_text
    @src_text ||= TextView.new(
      on_activate:          -> { on_src_activated },
      on_font_size_changed: ->(size) { dest_text.font_size_quietly = size },
      settings:             settings,
    )
  end

  def src_pron_revealer = @src_pron_revealer ||= pron_revealer
  def src_pron_scroll = @src_pron_scroll ||= pron_scroll
  def src_pron_label = @src_pron_label ||= pron_label

  def mistakes
    @mistakes ||= Gtk::Revealer.new.tap do |revealer|
      revealer.can_focus = false
      revealer.reveal_child = false
    end
  end

  def mistakes_box
    @mistakes_box ||= Gtk::Box.new(:horizontal, 8).tap do |box|
      box.can_focus = false
      box.add_css_class('card')
      box.add_css_class('mistakes')
    end
  end

  def mistakes_icon
    @mistakes_icon ||= Gtk::Image.new(icon_name: 'error-correct-symbolic').tap do |image|
      image.can_focus = false
    end
  end

  def mistakes_label
    @mistakes_label ||= Gtk::Label.new.tap do |label|
      label.can_focus = false
      label.wrap = true
      label.wrap_mode = :word_char
    end
  end

  def src_toolbar
    @src_toolbar ||= Gtk::Box.new(:horizontal, 0).tap do |box|
      box.add_css_class('toolbar')
    end
  end

  def clear_btn = @clear_btn ||= action_button('win.clear', 'Clear', 'edit-clear-symbolic')
  def paste_btn = @paste_btn ||= action_button('win.paste', 'Paste', 'edit-paste-symbolic')

  def char_counter
    @char_counter ||= Gtk::Label.new.tap do |label|
      label.margin_start = 4
      label.margin_end = 4
      label.hexpand = true
      label.halign = :end
      label.add_css_class('dim-label')
      label.add_css_class('caption-heading')
      label.add_css_class('numeric')
    end
  end

  def translate_btn
    @translate_btn ||= Gtk::Button.new(label: 'Translate').tap do |button|
      button.action_name = 'win.translation'
      button.add_css_class('suggested-action')
    end
  end

  # Destination side

  def dest_box = @dest_box ||= side_box
  def dest_scroll = @dest_scroll ||= translation_scroll

  def dest_text
    @dest_text ||= TextView.new(
      editable:             false,
      on_font_size_changed: ->(size) { src_text.font_size_quietly = size },
      settings:             settings,
    )
  end

  def dest_pron_revealer = @dest_pron_revealer ||= pron_revealer
  def dest_pron_scroll = @dest_pron_scroll ||= pron_scroll
  def dest_pron_label = @dest_pron_label ||= pron_label

  def dest_toolbar_stack
    @dest_toolbar_stack ||= Gtk::Stack.new.tap do |stack|
      stack.transition_type = :crossfade
    end
  end

  def dest_toolbar
    @dest_toolbar ||= Gtk::Box.new(:horizontal, 0).tap do |box|
      box.add_css_class('toolbar')
    end
  end

  def trans_spinner
    @trans_spinner ||= Adwaita::Spinner.new.tap do |spinner|
      spinner.tooltip_text = 'Translating…'
      spinner.margin_start = 8
      spinner.visible = false
    end
  end

  def trans_warning
    @trans_warning ||= Gtk::Image.new(icon_name: 'dialog-warning-symbolic').tap do |image|
      image.tooltip_text = 'Could not Translate the Text'
      image.margin_start = 8
      image.visible = false
    end
  end

  def copy_btn
    @copy_btn ||= action_button('win.copy', 'Copy', 'edit-copy-symbolic').tap do |button|
      button.hexpand = true
      button.halign = :end
    end
  end

  def edit_btn = @edit_btn ||= action_button('win.suggest', 'Suggest Translation', 'document-edit-symbolic')

  def edit_toolbar
    @edit_toolbar ||= Gtk::Box.new(:horizontal, 0).tap do |box|
      box.add_css_class('toolbar')
    end
  end

  def cancel_btn
    @cancel_btn ||= Gtk::Button.new(label: 'Cancel').tap do |button|
      button.action_name = 'win.suggest-cancel'
      button.hexpand = true
      button.halign = :end
    end
  end

  def save_btn
    @save_btn ||= Gtk::Button.new(label: 'Save').tap do |button|
      button.action_name = 'win.suggest-ok'
      button.add_css_class('suggested-action')
    end
  end

  # The narrow-window breakpoint, upstream's "max-width: 680px".
  def breakpoint
    @breakpoint ||= Adwaita::Breakpoint.new(Adwaita::BreakpointCondition.parse('max-width: 680px'))
  end

  # Not memoized: upstream rebuilds the Translate row's accelerator and
  # visibility from Settings every time the window is shown, and a fresh
  # dialog is the same thing said once.
  def shortcuts_window = ShortcutsWindow.new(settings: settings).build

  private

    # --- assembly -------------------------------------------------------

    def build_loading_page
      loading_handle.tap do |handle|
        handle.child = loading_page

        loading_page.tap do |page|
          page.paintable = Adwaita::SpinnerPaintable.new(page)
        end
      end
    end

    def build_error_page
      error_toolbar.tap do |view|
        view.add_top_bar(error_header)
        view.content = error_page

        error_page.tap do |page|
          page.child = error_buttons

          error_buttons.tap do |box|
            box.append(error_retry_btn)
            box.append(error_open_prefs_btn)

            error_retry_btn.signal_connect('clicked') { reload_provider('translator') }
            error_open_prefs_btn.action_name = 'app.preferences'
          end
        end
      end

      mobile_buttons_size
    end

    def build_key_page
      key_toolbar.tap do |view|
        view.add_top_bar(key_header)
        view.content = key_page

        key_page.tap do |page|
          page.child = key_buttons

          key_buttons.tap do |box|
            box.append(rmv_key_btn)
            box.append(key_open_prefs_btn)

            rmv_key_btn.signal_connect('clicked') { on_remove_key_and_reload }
            key_open_prefs_btn.action_name = 'app.preferences'
          end
        end
      end
    end

    def build_translate_page
      toast_overlay.tap do |overlay|
        overlay.child = multi_layout

        multi_layout.tap do |layouts|
          layouts.add_layout(desktop_layout)
          layouts.add_layout(mobile_layout)

          layouts.set_child('menu', menu_btn)
          layouts.set_child('back-btn', return_btn)
          layouts.set_child('forward-btn', forward_btn)
          layouts.set_child('langs-selector', langs_button_box)
          layouts.set_child('translation', translator_box)

          layouts.layout_name = DESKTOP_LAYOUT
        end
      end

      build_desktop_layout
      build_mobile_layout
      build_menu_button
      build_langs_box
      build_translator_box
    end

    def build_desktop_layout
      desktop_toolbar.tap do |view|
        view.add_top_bar(desktop_header)
        view.content = desktop_translation_slot

        desktop_header.tap do |header|
          header.title_widget = desktop_langs_slot
          header.pack_start(desktop_back_slot)
          header.pack_start(desktop_forward_slot)
          header.pack_end(desktop_menu_slot)
        end
      end
    end

    def build_mobile_layout
      mobile_toolbar.tap do |view|
        view.add_top_bar(mobile_header)
        view.content = mobile_translation_slot
        view.add_bottom_bar(mobile_langs_slot)

        mobile_header.tap do |header|
          header.pack_start(mobile_back_slot)
          header.pack_start(mobile_forward_slot)
          header.pack_end(mobile_menu_slot)
        end
      end
    end

    # The theme switcher goes into the menu's custom slot, which is only
    # reachable once the MenuButton has built its popover from the model.
    def build_menu_button
      menu_btn.popover.add_child(theme_switcher.build, MainMenu::THEME_SLOT)
    end

    def build_langs_box
      langs_button_box.tap do |box|
        box.append(src_lang_selector.build)
        box.append(switch_btn)
        box.append(dest_lang_selector.build)
      end

      langs_size_group
    end

    def build_translator_box
      translator_box.tap do |box|
        box.append(src_box)
        box.append(dest_box)
      end

      build_src_box
      build_dest_box
    end

    def build_src_box
      src_box.tap do |box|
        box.append(src_scroll)
        box.append(src_pron_revealer)
        box.append(mistakes)
        box.append(src_toolbar)

        src_scroll.child = src_text.build

        src_pron_revealer.tap do |revealer|
          revealer.child = src_pron_scroll
          src_pron_scroll.child = src_pron_label
        end

        mistakes.tap do |revealer|
          revealer.child = mistakes_box

          mistakes_box.tap do |container|
            container.append(mistakes_icon)
            container.append(mistakes_label)

            mistakes_label.signal_connect('activate-link') { on_mistakes_clicked }
          end
        end

        src_toolbar.tap do |toolbar|
          toolbar.append(clear_btn)
          toolbar.append(paste_btn)
          toolbar.append(char_counter)
          toolbar.append(translate_btn)
        end
      end
    end

    def build_dest_box
      dest_box.tap do |box|
        box.append(dest_scroll)
        box.append(dest_pron_revealer)
        box.append(dest_toolbar_stack)

        dest_scroll.child = dest_text.build

        dest_pron_revealer.tap do |revealer|
          revealer.child = dest_pron_scroll
          dest_pron_scroll.child = dest_pron_label
        end

        dest_toolbar_stack.tap do |stack|
          stack.add_named(dest_toolbar, 'default')
          stack.add_named(edit_toolbar, 'edit')
          stack.visible_child_name = 'default'

          dest_toolbar.tap do |toolbar|
            toolbar.append(trans_spinner)
            toolbar.append(trans_warning)
            toolbar.append(copy_btn)
            toolbar.append(edit_btn)
          end

          edit_toolbar.tap do |toolbar|
            toolbar.append(cancel_btn)
            toolbar.append(save_btn)
          end
        end
      end
    end

    # Upstream's breakpoint setters, as apply and unapply handlers.
    def build_breakpoint
      breakpoint.tap do |point|
        point.signal_connect('apply') { apply_mobile_layout(true) }
        point.signal_connect('unapply') { apply_mobile_layout(false) }
      end
    end

    def apply_mobile_layout(mobile)
      if mobile
        multi_layout.layout_name = MOBILE_LAYOUT
        error_buttons.orientation = :vertical
        key_buttons.orientation = :vertical
        translator_box.orientation = :vertical
        mobile_buttons_size.mode = :horizontal
        translator_box.add_css_class('vertical')
      else
        multi_layout.layout_name = DESKTOP_LAYOUT
        error_buttons.orientation = :horizontal
        key_buttons.orientation = :horizontal
        translator_box.orientation = :horizontal
        mobile_buttons_size.mode = :none
        translator_box.remove_css_class('vertical')
      end
    end

    # --- shared widget shapes -------------------------------------------

    def side_box
      Gtk::Box.new(:vertical, 0).tap do |box|
        box.overflow = :hidden
        box.add_css_class('card')
        box.add_css_class('translation-side-box')
      end
    end

    def translation_scroll
      Gtk::ScrolledWindow.new.tap do |scroll|
        scroll.vexpand = true
        scroll.add_css_class('translation-scrolled')
      end
    end

    def pron_revealer
      Gtk::Revealer.new.tap do |revealer|
        revealer.transition_type = :slide_down
        revealer.reveal_child = false
      end
    end

    def pron_scroll
      Gtk::ScrolledWindow.new.tap do |scroll|
        scroll.add_css_class('translation-scrolled')
        scroll.add_css_class('top-undershoot')
      end
    end

    def pron_label
      Gtk::Label.new.tap do |label|
        label.xalign = 0
        label.wrap = true
        label.wrap_mode = :word_char
        label.selectable = true
        label.valign = :end
        label.add_css_class('pronunciation')
        label.add_css_class('dim-label')
      end
    end

    def pill_button(label, suggested: false)
      Gtk::Button.new(label: label).tap do |button|
        button.can_shrink = true
        button.add_css_class('pill')

        if suggested
          button.add_css_class('suggested-action')
        end
      end
    end

    def action_button(action, tooltip, icon)
      Gtk::Button.new.tap do |button|
        button.action_name = action
        button.tooltip_text = tooltip
        button.icon_name = icon
      end
    end

    # --- actions ---------------------------------------------------------

    def setup_actions
      ACTIONS.each do |name, enabled|
        Gio::SimpleAction.new(name, nil).tap do |action|
          action.enabled = enabled
          action.signal_connect('activate') { activate_action(name) }
          window.add_action(action)
        end
      end
    end

    def activate_action(name)
      case name
      when 'back' then on_back_action
      when 'forward' then on_forward_action
      when 'switch' then on_switch_action
      when 'from' then src_lang_selector.popup
      when 'to' then dest_lang_selector.popup
      when 'clear' then on_clear_action
      when 'font-size-inc' then src_text.font_size_inc
      when 'font-size-dec' then src_text.font_size_dec
      when 'paste' then on_paste_action
      when 'copy' then on_copy_action
      when 'suggest' then on_suggest_action
      when 'suggest-ok' then on_suggest_ok_action
      when 'suggest-cancel' then on_suggest_cancel_action
      when 'translation' then run_translation
      when 'show-help-overlay' then shortcuts_window.present(window)
      end
    end

    def action(name) = window.lookup_action(name)

    def enable_action(name, enabled)
      action(name)&.enabled = enabled
    end

    # --- provider loading ------------------------------------------------

    def setup_selectors
      ->(code) { lang_name_for(code) }.then do |names_func|
        @src_lang_model = LanguagesListModel.new(names_func: names_func)
        @src_recent_lang_model = LanguagesListModel.new(names_func: names_func)
        @dest_lang_model = LanguagesListModel.new(names_func: names_func)
        @dest_recent_lang_model = LanguagesListModel.new(names_func: names_func)
      end

      src_lang_selector.bind_models(@src_lang_model, @src_recent_lang_model)
      dest_lang_selector.bind_models(@dest_lang_model, @dest_recent_lang_model)
    end

    def lang_name_for(code)
      @provider['trans'].then do |trans|
        if trans
          trans.get_lang_name(code)
        else
          Languages.lang_name(code)
        end
      end
    end

    def setup_translation
      src_text.buffer.tap do |buffer|
        buffer.signal_connect('changed') { on_src_text_changed(buffer) }
        buffer.signal_connect('end-user-action') { on_user_action_ended }
      end

      dest_text.buffer.tap do |buffer|
        buffer.text = ''
        buffer.signal_connect('changed') { on_dest_text_changed(buffer) }
      end

      apply_translate_accel

      if settings.custom_default_font_size && settings.default_font_size.positive?
        set_font_size(settings.default_font_size)
      end
    end

    # Upstream's load_translator, run off the main loop by BackgroundTask
    # rather than awaited.
    def load_translator
      self.translator_loading = true
      main_stack.visible_child_name = LOADING_PAGE
      rmv_key_btn.visible = false

      Providers::TRANSLATORS[settings.active_translator].then do |provider_class|
        if provider_class.nil?
          self.translator_loading = false
          show_translator_error_view(detail: "No provider is registered as #{settings.active_translator}")
        else
          start_translator_load(provider_class.new)
        end
      end
    end

    def start_translator_load(trans)
      @provider['trans'] = trans
      @src_langs = trans.recent_src_langs
      @dest_langs = trans.recent_dest_langs

      trans.settings.on_api_key_changed do
        unless @translator_loading
          reload_provider('translator')
        end
      end

      BackgroundTask.run(
        on_success: ->(_result) { finish_translator_load(trans) },
        on_error:   ->(exc) { fail_translator_load(trans, exc) },
      ) { trans.init_trans }
    end

    def finish_translator_load(trans)
      check_navigation_enabled
      check_mistakes
      check_pronunciation
      on_suggest_cancel_action
      edit_btn.visible = trans.supports_suggestions?

      @src_lang_model.set_langs(trans.src_languages)
      @dest_lang_model.set_langs(trans.dest_languages)

      src_lang_selector.selected = initial_src_lang(trans)
      dest_lang_selector.selected = initial_dest_lang(trans)

      update_char_counter(src_text.char_count)

      if trans.supports_api_key?
        check_api_key(trans)
      else
        self.translator_loading = false
        main_stack.visible_child_name = TRANSLATE_PAGE
      end
    end

    def initial_src_lang(trans)
      (settings.src_auto && trans.supports_detection?).then do |set_auto|
        if set_auto
          LangSelector::AUTO_CODE
        elsif @src_langs.first && trans.src_languages.include?(@src_langs.first)
          @src_langs.first
        else
          trans.src_languages.first.to_s
        end
      end
    end

    def initial_dest_lang(trans)
      if @dest_langs.first && trans.dest_languages.include?(@dest_langs.first)
        @dest_langs.first
      else
        # Upstream takes dest_languages[1] as the default, so a provider whose
        # first two dest langs are the same as the src side does not open on a
        # src == dest pair.
        (trans.dest_languages[1] || trans.dest_languages.first).to_s
      end
    end

    # Upstream's API key branch of load_translator.
    def check_api_key(trans)
      if !trans.api_key.to_s.empty?
        validate_api_key(trans)
      elsif trans.api_key_required?
        self.translator_loading = false
        show_translator_api_key_view(required: true)
      else
        self.translator_loading = false
        main_stack.visible_child_name = TRANSLATE_PAGE
      end
    end

    def validate_api_key(trans)
      BackgroundTask.run(
        on_success: lambda { |valid|
          self.translator_loading = false

          if valid
            main_stack.visible_child_name = TRANSLATE_PAGE
          else
            show_translator_api_key_view
          end
        },
        on_error:   lambda { |exc|
          self.translator_loading = false
          show_translator_error_view(detail: exc.message)
        },
      ) { trans.validate_api_key(trans.api_key) }
    end

    # Upstream's except branch of load_translator.
    def fail_translator_load(trans, exc)
      self.translator_loading = false

      case exc
      when APIKeyRequired then show_translator_api_key_view(required: true)
      when APIKeyInvalid then show_translator_api_key_view
      when RequestError then show_request_error_view(trans, exc)
      when ProviderError then show_provider_error_view(trans, exc)
      else show_translator_error_view(detail: exc.message)
      end
    end

    def show_request_error_view(trans, exc)
      if trans.supports_instances?
        show_translator_error_view(
          title:       'Unable to connect to the translation service.',
          description: "Unable to connect to the #{trans.prettyname} instance “#{trans.instance_url}“.\n" \
                       'Please check for network issues or if the address is correct.',
          detail:      exc.message,
        )
      else
        show_translator_error_view(
          title:       'Unable to connect to the translation service.',
          description: 'Unable to connect to the server. Please check for network issues.',
          detail:      exc.message,
        )
      end
    end

    def show_provider_error_view(trans, exc)
      if trans.supports_instances?
        show_translator_error_view(
          description: "Failed loading “#{trans.instance_url}“, check if the instance address is correct " \
                       'or report in the Dialect bug tracker if the issue persists.',
          detail:      exc.message,
        )
      else
        show_translator_error_view(detail: exc.message)
      end
    end

    def error_description(description, detail)
      if detail.to_s.empty?
        description
      else
        [description, "<small><tt>#{escape_markup(detail)}</tt></small>"]
          .reject { |part| part.to_s.empty? }
          .join("\n\n")
      end
    end

    # The status page's description is Pango markup, so a detail carrying an
    # ampersand or an angle bracket — a URL with a query string, an error from
    # an HTML error page — would make the markup unparseable and the whole
    # description would be dropped. Upstream interpolates the detail raw and
    # has the same hole; GLib.markup_escape_text is not bound in the Ruby
    # bindings, so the three characters Pango cares about are escaped here.
    def escape_markup(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def translator_loading=(state)
      @translator_loading = state
      @loading_observers.each { |observer| observer.call(state) }
      state
    end

    def on_remove_key_and_reload
      with_trans(&:reset_api_key)
      reload_provider('translator')
    end

    # --- history ---------------------------------------------------------

    def add_history_entry(translation)
      with_trans do |trans|
        if @current_history.positive?
          trans.history.slice!(0, @current_history)
          @current_history = 0
        end

        if trans.history.length == Define::TRANS_NUMBER
          trans.history.pop
        end

        trans.history.insert(0, translation)
        check_navigation_enabled
      end
    end

    def current_translation
      @provider['trans'].then do |trans|
        if trans
          trans.history[@current_history]
        end
      end
    end

    def check_navigation_enabled
      with_trans do |trans|
        enable_action('back', @current_history < trans.history.length - 1)
        enable_action('forward', @current_history.positive?)
      end
    end

    def on_back_action
      unless @current_history == Define::TRANS_NUMBER
        @current_history += 1
        history_update
      end
    end

    def on_forward_action
      unless @current_history.zero?
        @current_history -= 1
        history_update
      end
    end

    def history_update
      current_translation.then do |translation|
        if translation
          src_lang_selector.selected = translation.original.src
          dest_lang_selector.selected = translation.original.dest
          src_text.text = translation.original.text
          dest_text.text = translation.text

          check_navigation_enabled
          check_mistakes
          check_pronunciation
        end
      end
    end

    # --- mistakes and pronunciation --------------------------------------

    def check_mistakes
      with_trans do |trans|
        current_translation.then do |translation|
          if trans.supports_mistakes? && translation&.mistakes
            mistakes_label.set_markup("Did you mean: <a href=\"#\">#{translation.mistakes.markup}</a>")
            mistakes.reveal_child = true
          else
            mistakes.reveal_child = false
          end
        end
      end
    end

    def reveal_pronunciations(reveal)
      current_translation.then do |translation|
        if translation&.pronunciation&.src && !translation.mistakes
          src_pron_label.label = translation.pronunciation.src
          src_pron_revealer.reveal_child = reveal
        else
          src_pron_revealer.reveal_child = false
        end

        if translation&.pronunciation&.dest
          dest_pron_label.label = translation.pronunciation.dest
          dest_pron_revealer.reveal_child = reveal
        else
          dest_pron_revealer.reveal_child = false
        end
      end
    end

    def on_mistakes_clicked
      mistakes.reveal_child = false

      current_translation.then do |translation|
        if translation&.mistakes
          src_text.text = translation.mistakes.text
          src_lang_selector.selected = translation.original.src
          dest_lang_selector.selected = translation.original.dest
        end
      end

      run_translation
      true
    end

    # --- language selection ----------------------------------------------

    def on_src_lang_changed
      with_trans do |trans|
        src_lang_selector.selected.then do |code|
          dest_lang_selector.selected.then do |dest_code|
            if trans.cmp_langs(code, dest_code)
              dest_lang_selector.selected = replacement_lang(@src_langs, dest_code, trans.dest_languages)
            end
          end

          if trans.src_languages.include?(code)
            remember_lang(@src_langs, code)
          end

          @src_recent_lang_model.set_langs(@src_langs, auto: trans.supports_detection?)
        end

        check_switch_enabled
      end
    end

    def on_dest_lang_changed
      with_trans do |trans|
        dest_lang_selector.selected.then do |code|
          src_lang_selector.selected.then do |src_code|
            if trans.cmp_langs(code, src_code)
              src_lang_selector.selected = replacement_lang(@dest_langs, src_code, trans.src_languages)
            end
          end

          remember_lang(@dest_langs, code)
          @dest_recent_lang_model.set_langs(@dest_langs)
        end

        check_switch_enabled
      end
    end

    # Upstream's "first saved lang that is not the other side's, and is valid
    # there; otherwise the first one in the list that is not it".
    def replacement_lang(recent, exclude, available)
      Utils.first_exclude(recent, exclude).then do |candidate|
        Utils.find_item_match([candidate].compact, available).then do |valid|
          valid || Utils.first_exclude(available, exclude).to_s
        end
      end
    end

    # Brings a code to the top of a recent list, dropping the oldest once the
    # list is full.
    def remember_lang(recent, code)
      if recent.include?(code)
        recent.delete(code)
      elsif recent.include?(code.downcase)
        recent.delete(code.downcase)
      elsif recent.length == RECENT_LANGS
        recent.pop
      end

      recent.insert(0, code)
    end

    def check_switch_enabled
      with_trans do |trans|
        enable_action(
          'switch',
          trans.dest_languages.include?(src_lang_selector.selected) &&
            trans.src_languages.include?(dest_lang_selector.selected),
        )
      end
    end

    def on_switch_action
      src_lang_selector.selected.then do |src_language|
        unless src_language == LangSelector::AUTO_CODE
          switch_languages(src_language)
        end
      end
    end

    def switch_languages(src_language)
      langs_button_box.sensitive = false
      enable_action('translation', false)

      dest_lang_selector.selected.then do |dest_language|
        [src_text.text, dest_text.text].then do |(source, destination)|
          src_lang_selector.selected = dest_language
          dest_lang_selector.selected = src_language
          src_text.text = destination
          dest_text.text = source

          add_history_entry(
            Translation.new(
              text:     source,
              original: TranslationRequest.new(text: destination, src: dest_language, dest: src_language),
            ),
          )
        end
      end

      langs_button_box.sensitive = true
      enable_action('translation', !src_text.char_count.zero?)
    end

    # --- text, clipboard and suggestions ---------------------------------

    def on_clear_action
      src_text.text = ''
      src_text.buffer.signal_emit('end-user-action')
    end

    def on_copy_action
      Gdk::Display.default.then do |display|
        if display
          display.clipboard.set(dest_text.text)
          send_notification('Copied to clipboard', timeout: 1)
        end
      end
    end

    def on_paste_action
      Gdk::Display.default.then do |display|
        if display
          display.clipboard.read_text_async do |clipboard, result|
            paste_text(clipboard, result)
          end
        end
      end
    end

    def paste_text(clipboard, result)
      clipboard.read_text_finish(result).then do |text|
        unless text.to_s.empty?
          src_text.buffer.insert(src_text.buffer.end_iter, text)
          src_text.buffer.signal_emit('end-user-action')
        end
      end
    rescue StandardError
      send_notification('Unable to read the clipboard.')
    end

    def translate_selection(src_lang, dest_lang)
      Gdk::Display.default.then do |display|
        if display
          display.primary_clipboard.read_text_async do |clipboard, result|
            translate_selection_text(
              clipboard,
              result,
              src_lang,
              dest_lang,
            )
          end
        end
      end
    end

    def translate_selection_text(clipboard, result, src_lang, dest_lang)
      clipboard.read_text_finish(result).then do |text|
        unless text.to_s.empty?
          translate(text, src_lang, dest_lang)
        end
      end
    rescue StandardError
      send_notification('Unable to read the selected text.')
    end

    def on_suggest_action
      dest_toolbar_stack.visible_child_name = 'edit'
      @before_suggest = dest_text.text
      dest_text.editable = true
    end

    def on_suggest_ok_action
      with_trans do |trans|
        current_translation.then do |translation|
          if translation
            send_suggestion(trans, translation, dest_text.text)
          else
            finish_suggestion
          end
        end
      end
    end

    def send_suggestion(trans, translation, suggestion)
      BackgroundTask.run(
        on_success: lambda { |accepted|
          if accepted
            send_notification('New translation has been suggested!')
          else
            send_notification('Suggestion failed.')
          end

          finish_suggestion
        },
        on_error:   lambda { |_exc|
          send_notification('Suggestion failed.')
          finish_suggestion
        },
      ) do
        trans.suggest(
          translation.original.text,
          translation.original.src,
          translation.original.dest,
          suggestion,
        )
      end
    end

    def finish_suggestion
      dest_toolbar_stack.visible_child_name = 'default'
      dest_text.editable = false
      @before_suggest = nil
    end

    def on_suggest_cancel_action
      dest_toolbar_stack.visible_child_name = 'default'

      unless @before_suggest.nil?
        dest_text.text = @before_suggest
        @before_suggest = nil
      end

      dest_text.editable = false
    end

    # --- buffer changes --------------------------------------------------

    def on_src_text_changed(buffer)
      with_trans do |trans|
        buffer.char_count.then do |char_count|
          update_char_counter(char_count)

          if trans.chars_limit != -1 && char_count >= trans.chars_limit
            send_notification("#{trans.chars_limit} characters limit reached!")
            buffer.delete(buffer.get_iter_at(offset: trans.chars_limit), buffer.end_iter)
          end

          enable_action('translation', !char_count.zero?)
          enable_action('clear', !char_count.zero?)
        end
      end
    end

    def update_char_counter(char_count)
      with_trans do |trans|
        if trans.chars_limit == -1
          char_counter.label = ''
        else
          char_counter.label = "#{char_count}/#{trans.chars_limit}"
        end
      end
    end

    def on_dest_text_changed(buffer)
      with_trans do |trans|
        (!buffer.char_count.zero?).then do |sensitive|
          enable_action('copy', sensitive)
          enable_action('suggest', trans.supports_suggestions? && sensitive)
        end
      end
    end

    def on_user_action_ended
      if settings.live_translation
        run_translation
      end
    end

    def on_src_activated
      unless settings.live_translation
        run_translation
      end
    end

    def on_is_active_changed
      if @selection_translation_queued && window.is_active?
        @selection_translation_queued = false
        @selection_translation_langs.then do |(src, dest)|
          @selection_translation_langs = [nil, nil]
          translate_selection(src, dest)
        end
      end
    end

    # Typing anywhere in the window goes into the source view, upstream's
    # _on_key_event.
    def on_key_event(keyval, state)
      (state & Gtk.accelerator_get_default_mod_mask).then do |modifiers|
        Gdk::Keyval.to_unicode(keyval).then do |unicode|
          if typing_should_focus_source?(modifiers, unicode)
            src_text.grab_focus
            src_text.buffer.insert(src_text.buffer.end_iter, unicode.chr(Encoding::UTF_8))
            true
          else
            false
          end
        end
      end
    end

    # Upstream asks GLib.unichar_isgraph; the Ruby bindings expose no such
    # function, and Ruby's own [[:graph:]] class is the same test.
    def typing_should_focus_source?(modifiers, unicode)
      unicode.positive? &&
        unicode.chr(Encoding::UTF_8).match?(/[[:graph:]]/) &&
        [Gdk::ModifierType::SHIFT_MASK, Gdk::ModifierType::NO_MODIFIER_MASK].include?(modifiers) &&
        !dest_text.editable? &&
        !src_text.is_focus?
    end

    # --- translation -----------------------------------------------------

    def run_translation
      with_trans do |trans|
        unless appeared_before?
          next_request.then do |request|
            if request
              start_translation(trans, request)
            end
          end
        end
      end
    end

    # The queued request if there is one, a fresh one otherwise — and nothing
    # at all when a translation is already running, which is upstream's way of
    # coalescing keystrokes into one more request.
    def next_request
      if @next_translation
        @next_translation.tap { @next_translation = nil }
      else
        TranslationRequest.new(
          text: src_text.text,
          src:  src_lang_selector.selected,
          dest: dest_lang_selector.selected,
        ).then do |request|
          if @translation_loading
            @next_translation = request
            nil
          else
            request
          end
        end
      end
    end

    def start_translation(trans, request)
      trans_spinner.visible = true
      dest_box.sensitive = false
      langs_button_box.sensitive = false

      if request.src != request.dest && !request.text.empty?
        @translation_loading = true

        BackgroundTask.run(
          on_success: ->(translation) { translation_succeeded(trans, translation) },
          on_error:   ->(exc) { translation_failed(exc) },
        ) { trans.translate(request) }
      else
        dest_text.text = ''

        unless @translation_loading
          translation_finish
        end
      end
    end

    def translation_succeeded(trans, translation)
      @translation_loading = false

      if translation.detected && src_lang_selector.selected == LangSelector::AUTO_CODE
        if settings.src_auto
          src_lang_selector.set_insight(trans.normalize_lang_code(translation.detected))
        else
          src_lang_selector.selected = translation.detected
        end
      end

      dest_text.text = translation.text
      add_history_entry(translation)

      check_mistakes
      check_pronunciation
      trans_warning.visible = false

      after_translation
    end

    def translation_failed(exc)
      @translation_loading = false
      trans_warning.visible = true
      enable_action('copy', false)

      case exc
      when RequestError
        send_notification(
          'Translation failed, check for network issues',
          action: { label: 'Retry', name: 'win.translation' },
        )
      when APIKeyInvalid
        send_notification(
          'The provided API key is invalid',
          action: { label: 'Retry', name: 'win.translation' },
        )
      when APIKeyRequired
        send_notification(
          'API key is required to use the service',
          action: { label: 'Preferences', name: 'app.preferences' },
        )
      else
        send_notification(
          'Translation failed',
          action: { label: 'Retry', name: 'win.translation' },
        )
      end

      after_translation
    end

    def after_translation
      if @next_translation
        run_translation
      else
        translation_finish
      end
    end

    def translation_finish
      trans_spinner.visible = false
      dest_box.sensitive = true
      langs_button_box.sensitive = true
    end

    # Upstream's _appeared_before: the same text in the same two languages as
    # the translation already on screen is not worth asking for again.
    def appeared_before?
      @provider['trans'].then do |trans|
        current_translation.then do |translation|
          !trans.nil? &&
            trans.history.length >= @current_history + 1 &&
            !translation.nil? &&
            [translation.original.src, LangSelector::AUTO_CODE].include?(src_lang_selector.selected) &&
            translation.original.dest == dest_lang_selector.selected &&
            translation.original.text == src_text.text
        end
      end
    end

    # Runs the block with the live translation provider, or does nothing when
    # there is none — upstream's `if not self.provider["trans"]: return`.
    def with_trans
      @provider['trans'].then do |trans|
        if trans
          yield trans
        end
      end
    end
end
