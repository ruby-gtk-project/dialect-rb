# frozen_string_literal: true

# Drives the whole dialect port headlessly: builds the application window,
# asserts every widget it claims to have, and exercises each of the non-widget
# units in lib/ against real behaviour — settings written to and read back off
# disk, secrets migrated between files, HTTP requests served by a loopback
# server started by this script, and BackgroundTask delivering its result on
# the GLib main loop.
#
# Why this file exists: a GTK app that loads is not a GTK app that works.
# `ruby -c` passes on code that builds an empty window, and the Ruby bindings
# differ from the C API in ways only a run reveals.
#
# Run it from the repository root:
#
#   nix develop --command xvfb-run -a ruby test/drive_dialect.rb
#
# Despite what the companion skill says, GTK4 here has no offscreen backend —
# gtk_init fails outright with no display — so xvfb-run is not optional on
# this machine.
#
# SCOPE. The port's UI is still the scaffold: `lib/dialect/application.rb`
# builds one Adwaita::ApplicationWindow holding a ToolbarView, a HeaderBar and
# an Adwaita::StatusPage that says in so many words that the translation
# window is not written. There is therefore no translator window, no
# preferences dialog, no about dialog, no app menu, no lang selector and no
# GAction or accelerator to fire. This script asserts the absence of those
# explicitly (see the last step) rather than quietly covering less than it
# appears to: every component the port *does* claim is driven here.

require "fileutils"
require "json"
require "socket"
require "tmpdir"

# Scratch config and data directories, so a run never reads or writes the
# user's real settings or secrets.
SCRATCH = Dir.mktmpdir("dialect-drive")
ENV["XDG_CONFIG_HOME"] = File.join(SCRATCH, "config")
ENV["XDG_DATA_HOME"] = File.join(SCRATCH, "data")

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "dialect"
require_relative "gtk_driver"

# A translation provider that answers from memory, registered so the window
# can be driven without touching the network. Every provider upstream ships
# reaches its service in init_trans — Google fetches its language list on
# startup — so driving the real window against a real provider would make this
# script depend on the internet. The three checks that count the registry
# subtract this one by name.
class DriveProvider < Provider
  LANGS = { "en" => "English", "es" => "Spanish", "fr" => "French", "de" => "German" }.freeze
  CHARS_LIMIT = 120

  def self.provider_name = "drive"
  def self.prettyname = "Drive Probe"
  def self.capabilities = ProviderCapability::TRANSLATION

  def self.features
    ProviderFeature::DETECTION |
      ProviderFeature::MISTAKES |
      ProviderFeature::PRONUNCIATION |
      ProviderFeature::SUGGESTIONS
  end

  def init_trans
    LANGS.each { |code, name| add_lang(code, name) }
    self.chars_limit = CHARS_LIMIT
  end

  # Reverses the text, so a translation is recognisable without a service.
  def translate(request)
    Translation.new(
      text:          request.text.reverse,
      original:      request,
      detected:      "es",
      mistakes:      TranslationMistake.new(markup: "<b>hello</b>", text: "hello"),
      pronunciation: TranslationPronunciation.new(src: "src-pron", dest: "dest-pron"),
    )
  end

  def suggest(_text, _src, _dest, _suggestion) = true
end

Providers.register(DriveProvider)
Settings.get.active_translator = DriveProvider.provider_name

SHOTS = File.expand_path("../tmp/shots", __dir__)
FileUtils.rm_rf(SHOTS)

# The window size the app should restore on startup, written before the app
# builds so the window's memoized accessor has to read it back.
#
# It has to fit inside the virtual display: GTK clamps a window to the
# monitor, and `xvfb-run` here gives a 640x480 screen, so asking for anything
# wider comes back as 640 and the check would be measuring Xvfb, not the port.
WINDOW_SIZE = [600, 420].freeze
Settings.get.window_size = WINDOW_SIZE

# A loopback HTTP server, so Session and SessionHelpers are driven against
# real sockets without touching the network. Each connection serves one
# request and closes, which is what Session's Net::HTTP calls expect.
class HttpProbe
  attr_reader :port

  # Serves from a forked child process rather than a Ruby Thread in this
  # script's own process. Session's requests go through soup3's real
  # Soup::Session#send_and_read, a blocking call that the generic
  # GObjectIntrospection invoker does not release Ruby's global VM lock for
  # (unlike Net::HTTP's, which this port's session.rb used to call) — so a
  # same-process probe Thread would never get scheduled while a request to it
  # is in flight, and would time the request out rather than answering it.
  # Hit counts cross the fork through a plain log file instead of shared
  # memory: each hit appends one line, under PIPE_BUF, so concurrent appends
  # from the child stay atomic.
  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @log_path = File.join(Dir.mktmpdir("dialect-probe"), "hits.log")
    FileUtils.touch(@log_path)
    @pid = fork { accept_loop }
    @server.close
  end

  def url(path) = "http://127.0.0.1:#{port}#{path}"

  def hits(path) = File.readlines(@log_path).count { |line| line.strip == path }

  def stop
    Process.kill("TERM", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  private

    def accept_loop
      loop do
        @server.accept.then do |socket|
          begin
            serve(socket)
          rescue StandardError
            nil
          ensure
            socket.close
          end
        end
      end
    end

    def serve(socket)
      read_request(socket).then do |(method, path, headers, body)|
        File.open(@log_path, "a") { |f| f.write("#{path}\n") }

        socket.write(
          response_for(
            method,
            path,
            headers,
            body,
          ),
        )
      end
    end

    def read_request(socket)
      socket.gets.to_s.split.then do |(method, target, _version)|
        read_headers(socket).then do |headers|
          [method, target, headers, read_body(socket, headers)]
        end
      end
    end

    def read_headers(socket)
      {}.tap do |headers|
        done = false
        while !done && (line = socket.gets)
          if line.strip.empty?
            done = true
          else
            line.split(":", 2).then do |(name, value)|
              headers[name.to_s.downcase] = value.to_s.strip
            end
          end
        end
      end
    end

    def read_body(socket, headers)
      headers["content-length"].to_i.then do |length|
        if length.positive?
          socket.read(length).to_s
        else
          ""
        end
      end
    end

    def response_for(method, path, headers, body)
      case path
      when "/json" then http(200, JSON.generate({"ok" => true, "method" => method}))
      when "/text" then http(200, "plain words", type: "text/plain")
      when "/empty" then http(200, "")
      when "/agent" then http(200, JSON.generate({"agent" => headers["user-agent"].to_s}))
      when "/echo"
        http(200, JSON.generate({"type" => headers["content-type"].to_s, "body" => body, "method" => method}))
      when "/moved-keep" then redirect(308, "/echo")
      when "/moved-get" then redirect(302, "/echo")
      when "/moved-loop" then redirect(308, "/moved-loop")
      when "/flaky"
        # `@hits` was never a thing: each hit is counted off the log file (the
        # line `serve` just appended for this very request is in it already),
        # the same way the parent process's own `#hits` reads it back. The
        # unconditional `@hits["/flaky"]` this replaced called `[]` on a nil
        # ivar, which raised inside the forked child's `serve`, was swallowed
        # by `accept_loop`'s rescue, and left the socket closed with no
        # response ever written — every single request to `/flaky`, not just
        # a flaky fraction of them, so the retry policy this path exists to
        # exercise was never actually exercised.
        if File.readlines(@log_path).count { |line| line.strip == "/flaky" } < 2
          http(429, JSON.generate({"error" => "slow down"}))
        else
          http(200, JSON.generate({"ok" => true}))
        end
      when "/denied" then http(403, JSON.generate({"error" => "bad key"}))
      else http(404, JSON.generate({"error" => "no route"}))
      end
    end

    def http(status, body, type: "application/json")
      [
        "HTTP/1.1 #{status} X",
        "Content-Type: #{type}",
        "Content-Length: #{body.bytesize}",
        "Connection: close",
        "",
        body,
      ].join("\r\n")
    end

    def redirect(status, location)
      "".then do |body|
        [
          "HTTP/1.1 #{status} X",
          "Location: #{location}",
          "Content-Length: #{body.bytesize}",
          "Connection: close",
          "",
          body,
        ].join("\r\n")
      end
    end
end

PROBE = HttpProbe.new

# A port nothing is listening on, to provoke a genuine refused connection.
#
# This binds and immediately closes a TCPServer rather than using a
# well-known closed port such as 1: this sandbox's network stack intercepts
# an attempt to connect to a privileged low port and, having nothing of its
# own to refuse it with, appears to route the attempt into some other
# process's listening socket instead — observed here as it wedging the
# forked HttpProbe's single-threaded accept loop on a connection that never
# sends anything, so every request after the first "refused" one then times
# out for real. An unprivileged ephemeral port that this process itself just
# vacated is refused cleanly by the kernel and disturbs nothing else.
REFUSED_PORT = TCPServer.new('127.0.0.1', 0).then { |s| s.addr[1].tap { s.close } }

# A provider-shaped consumer of SessionHelpers with a retry policy and its own
# error payload check, which is the contract every real provider relies on.
class RetryProbe
  include SessionHelpers

  def retry_errors = [429]
  def max_retries = 2
end

class DeniedProbe
  include SessionHelpers

  def check_known_errors(status, data)
    if status == 403 && data["error"] == "bad key"
      raise APIKeyInvalid, "rejected"
    end
  end
end

# Turns the main loop over for `ms` milliseconds and comes back.
#
# A step cannot sleep on the main loop's own clock: every step runs inside a
# GLib timeout, so the idle callback BackgroundTask arms is dispatched by the
# very loop a sleep would block. This iterates the default context without
# blocking until the deadline passes.
def pump(ms)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) + (ms / 1000.0)).then do |deadline|
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      GLib::MainContext.default.iteration(false)
    end
  end
end

# Whether `widget` has `ancestor` somewhere above it in the tree.
def under?(widget, ancestor)
  widget.then do |node|
    current = node
    found = false
    while current && !found
      found = current.equal?(ancestor)
      current = current.parent
    end
    found
  end
end

# Collects whatever a block raises, so a check can assert on the class.
#
# ScriptError is caught as well as StandardError: the provider base class
# refuses with NotImplementedError, which is a ScriptError and would otherwise
# sail straight past the driver's own rescue and kill the run.
def raised_by
  yield
  nil
rescue StandardError, ScriptError => exc
  exc
end

GtkDriver.drive(Dialect::Application.new, shots: SHOTS) do |d, app|
  d.window { app.window.window }

  # --- 1. the application, 2. the window ----------------------------------

  d.step("the application window builds") do
    d.check("the application is a Gtk::Application") { app.app.is_a?(Gtk::Application) }
    d.check("its id is upstream's app id") { app.app.application_id == Define::APP_ID }
    d.check("libadwaita was initialized, so Adwaita widgets get their style") do
      Adwaita.initialized?
    end
    d.check("the Adwaita style manager is reachable") do
      !Adwaita::StyleManager.default.nil?
    end
    d.check("the window object is a Window") { app.window.is_a?(Window) }
    d.check("its root is an Adwaita::ApplicationWindow") do
      app.window.window.is_a?(Adwaita::ApplicationWindow)
    end
    d.check("it is the only toplevel") { Gtk::Window.list_toplevels.length == 1 }
    d.check("it belongs to the application") { app.app.windows.length == 1 }
    d.check("its title is Dialect") { app.window.window.title == "Dialect" }
    d.check("it is visible") { app.window.window.visible? }
    d.check("it restored the window size from settings") do
      [app.window.window.default_width, app.window.window.default_height] == WINDOW_SIZE
    end
    d.check("it carries upstream's minimum size") do
      app.window.window.width_request == 360 && app.window.window.height_request == 320
    end
    d.check("the main stack is the window content") do
      app.window.window.content.equal?(app.window.main_stack)
    end
    d.check("the stack crossfades, as upstream's does") do
      app.window.main_stack.transition_type.nick == "crossfade"
    end
    d.shot("01-main-window")
  end

  # --- 3. the four states of the main stack --------------------------------

  d.step("the main stack holds upstream's four pages") do
    app.window.main_stack.then do |stack|
      %w[loading error api-key translate].each do |name|
        d.check("the #{name} page is in the stack") { !stack.get_child_by_name(name).nil? }
      end
      d.check("the loading page is a window handle, so a blank app can be dragged") do
        stack.get_child_by_name("loading").is_a?(Gtk::WindowHandle)
      end
      d.check("it holds a status page with a spinner paintable") do
        app.window.loading_page.is_a?(Adwaita::StatusPage) &&
          app.window.loading_page.paintable.is_a?(Adwaita::SpinnerPaintable)
      end
      d.check("the loading page is titled Loading…") { app.window.loading_page.title == "Loading…" }
      d.check("the error page is an Adwaita::StatusPage under a toolbar view") do
        app.window.error_page.is_a?(Adwaita::StatusPage) &&
          under?(app.window.error_page, app.window.error_toolbar)
      end
      d.check("the api-key page carries upstream's password icon") do
        app.window.key_page.icon_name == "dialog-password-symbolic"
      end
      d.check("the translate page is a toast overlay") do
        stack.get_child_by_name("translate").equal?(app.window.toast_overlay)
      end
      d.check("the probe provider loaded, so the translate page is showing") do
        stack.visible_child_name == "translate"
      end
      d.check("and the window says loading has finished") { !app.window.translator_loading? }
      d.check("the live provider is the probe") do
        app.window.provider("trans").is_a?(DriveProvider)
      end
    end
  end

  # --- 4. the error state --------------------------------------------------

  d.step("the error view takes a title, a description and a detail") do
    app.window.show_translator_error_view(detail: "connection refused")
    pump(400)
    d.check("the stack switched to the error page") do
      app.window.main_stack.visible_child_name == "error"
    end
    d.check("the title is upstream's default") { app.window.error_page.title == Window::ERROR_TITLE }
    d.check("the description keeps upstream's default text") do
      app.window.error_page.description.start_with?(Window::ERROR_DESCRIPTION)
    end
    d.check("and appends the detail in monospace, as upstream does") do
      app.window.error_page.description.include?("<small><tt>connection refused</tt></small>")
    end
    d.check("the retry button is a pill with the suggested style") do
      app.window.error_retry_btn.css_classes.include?("pill") &&
        app.window.error_retry_btn.css_classes.include?("suggested-action")
    end
    d.check("the preferences button opens the app's preferences action") do
      app.window.error_open_prefs_btn.action_name == "app.preferences"
    end
    d.shot("02-error-state")
  end

  # --- 5. the API key state ------------------------------------------------

  d.step("the api-key view says whether a key is required or invalid") do
    app.window.show_translator_api_key_view(required: true)
    pump(400)
    d.check("the stack switched to the api-key page") do
      app.window.main_stack.visible_child_name == "api-key"
    end
    d.check("it says a key is required") do
      app.window.key_page.title == "API key is required to use the service"
    end
    d.check("and where to set one") do
      app.window.key_page.description == "Please set an API key in the preferences."
    end
    d.check("the remove-key button stays hidden when no key was set") do
      !app.window.rmv_key_btn.visible?
    end
    app.window.show_translator_api_key_view
    pump(400)
    d.check("an invalid key says so instead") do
      app.window.key_page.title == "The provided API key is invalid"
    end
    d.check("and offers to unset it, since the probe does not require one") do
      app.window.key_page.description.include?("unset the API key")
    end
    d.check("so the remove-key button appears") { app.window.rmv_key_btn.visible? }
    d.shot("03-api-key-state")
    app.window.main_stack.visible_child_name = "translate"
  end

  # --- 6. the multi-layout translation view --------------------------------

  d.step("the translate page holds both of upstream's layouts over one set of widgets") do
    app.window.multi_layout.then do |layouts|
      d.check("it is an Adwaita::MultiLayoutView") { layouts.is_a?(Adwaita::MultiLayoutView) }
      d.check("the desktop layout is registered") { !layouts.get_layout_by_name("desktop").nil? }
      d.check("the mobile layout is registered") { !layouts.get_layout_by_name("mobile").nil? }
      %w[menu back-btn forward-btn langs-selector translation].each do |slot|
        d.check("the #{slot} slot is filled") { !layouts.get_child(slot).nil? }
      end
      d.check("the menu slot holds the menu button") do
        layouts.get_child("menu").equal?(app.window.menu_btn)
      end
      d.check("the translation slot holds the translator box") do
        layouts.get_child("translation").equal?(app.window.translator_box)
      end
      d.check("the translator box carries upstream's style class") do
        app.window.translator_box.css_classes.include?("translation-box")
      end
      d.check("it is homogeneous, so both sides are the same width") do
        app.window.translator_box.homogeneous?
      end
    end
  end

  # --- 7. the narrow-window breakpoint --------------------------------------

  d.step("the breakpoint moves the window to the mobile layout") do
    d.check("the window has a breakpoint") { !app.window.breakpoint.nil? }
    d.check("its condition is upstream's max-width: 680px") do
      app.window.breakpoint.condition.to_s == "max-width: 680px"
    end
    # The virtual display is 640x480, so the window is already narrow and the
    # breakpoint has applied itself.
    d.check("the mobile layout is the one showing") do
      app.window.multi_layout.layout_name == "mobile"
    end
    d.check("the translation box stacks vertically") do
      app.window.translator_box.orientation.nick == "vertical"
    end
    d.check("and takes the vertical style class style.css expects") do
      app.window.translator_box.css_classes.include?("vertical")
    end
    d.check("the error buttons stack too") do
      app.window.error_buttons.orientation.nick == "vertical"
    end
    d.check("and share a width through the size group") do
      app.window.mobile_buttons_size.mode.nick == "horizontal"
    end
  end

  # --- 8. the app menu, 9. the theme switcher -------------------------------

  d.step("the menu button carries upstream's three-section app menu") do
    d.check("the menu button is primary, so F10 opens it") { app.window.menu_btn.primary? }
    d.check("it uses the hamburger icon") { app.window.menu_btn.icon_name == "open-menu-symbolic" }
    d.check("its popover is a Gtk::PopoverMenu") { app.window.menu_btn.popover.is_a?(Gtk::PopoverMenu) }
    app.window.main_menu.menu.then do |menu|
      d.check("the model has three sections") { menu.n_items == 3 }
    end
    d.check("the first section is the theme slot") do
      app.window.main_menu.theme_section.n_items == 1
    end
    d.check("the pronunciation toggle is in the second") do
      MainMenu::PREFERENCES_ITEMS["Show Pronunciation"] == "app.pronunciation"
    end
    d.check("preferences, shortcuts and about are in the third") do
      MainMenu::HELP_ITEMS.values == ["app.preferences", "win.show-help-overlay", "app.about"]
    end
    d.check("the theme switcher is a Gtk::Box with upstream's style class") do
      app.window.theme_switcher.is_a?(Gtk::Box) &&
        app.window.theme_switcher.css_classes.include?("themeswitcher")
    end
    d.check("it was added to the popover under the menu's custom slot id") do
      # A PopoverMenu's custom child is not in the widget tree until the
      # popover is first shown, so what can be asserted here is that the
      # switcher was adopted at all.
      !app.window.theme_switcher.parent.nil?
    end
    d.check("its three buttons share a group, so only one can be active") do
      app.window.theme_switcher.then do |switcher|
        switcher.system_button.active = true
        switcher.dark_button.active = true
        !switcher.system_button.active? && switcher.dark_button.active?
      end
    end
    d.check("each carries its scheme's style class") do
      %w[system light dark].all? do |scheme|
        app.window.theme_switcher.public_send("#{scheme}_button").css_classes.include?(scheme)
      end
    end
  end

  d.step("the theme switcher writes the chosen scheme to settings and the style manager") do
    app.window.theme_switcher.then do |switcher|
      switcher.dark_button.active = true
      pump(300)
      d.check("clicking dark selects it") { switcher.selected_color_scheme == "dark" }
      d.check("the style manager was told to force dark") do
        Adwaita::StyleManager.default.color_scheme == Adwaita::ColorScheme::FORCE_DARK
      end
      d.check("and the choice was saved") { Settings.get.color_scheme == "dark" }
      d.shot("04-dark-scheme")

      switcher.light_button.active = true
      pump(300)
      d.check("clicking light selects it") { switcher.selected_color_scheme == "light" }
      d.check("the style manager forces light") do
        Adwaita::StyleManager.default.color_scheme == Adwaita::ColorScheme::FORCE_LIGHT
      end
      d.check("and that is saved too") { Settings.get.color_scheme == "light" }

      switcher.selected_color_scheme = "auto"
      pump(300)
      d.check("auto checks the system button") { switcher.system_button.active? }
      d.check("and asks for upstream's PREFER_LIGHT") do
        Adwaita::StyleManager.default.color_scheme == Adwaita::ColorScheme::PREFER_LIGHT
      end
    end
  end

  # --- 10. the language selectors, 11. the language rows --------------------

  d.step("both language selectors show the provider's languages") do
    d.check("each is an Adwaita::Bin") do
      app.window.src_lang_selector.is_a?(Adwaita::Bin) &&
        app.window.dest_lang_selector.is_a?(Adwaita::Bin)
    end
    d.check("they are in the langs box with the switch button between them") do
      [
        app.window.src_lang_selector,
        app.window.switch_btn,
        app.window.dest_lang_selector,
      ].all? { |widget| widget.parent.equal?(app.window.langs_button_box) }
    end
    d.check("the src selector opened on Auto, since the probe detects languages") do
      app.window.src_lang_selector.selected == "auto"
    end
    d.check("and its label says so") { app.window.src_lang_selector.label.label == "Auto" }
    d.check("the dest selector opened on the provider's first saved dest lang") do
      # Provider::DEFAULTS puts "fr" first in dest_langs, and upstream prefers
      # a saved language over dest_languages[1] when it is still offered.
      app.window.dest_lang_selector.selected == "fr"
    end
    d.check("and its label is that language's name") do
      app.window.dest_lang_selector.label.label == "French"
    end
    d.check("the full list has one row per language") do
      app.window.dest_lang_selector.lang_list.observe_children.n_items == DriveProvider::LANGS.length
    end
    d.check("the rows are LangRows") do
      app.window.dest_lang_selector.lang_list.get_row_at_index(0).is_a?(LangRow)
    end
    d.check("sorted by name, not by code") do
      Array.new(DriveProvider::LANGS.length) do |i|
        app.window.dest_lang_selector.lang_list.get_row_at_index(i).lang.name
      end == DriveProvider::LANGS.values.sort
    end
    # Read as a property, not with visible?: that answers
    # gtk_widget_is_visible, which is false for everything inside a popover
    # that has never been shown, whatever the widget's own flag says.
    d.check("the selected row shows its check mark") do
      (0...DriveProvider::LANGS.length).any? do |i|
        app.window.dest_lang_selector.lang_list.get_row_at_index(i).then do |row|
          row.lang.code == "fr" && row.selection_image.get_property("visible")
        end
      end
    end
    d.check("and the others do not") do
      (0...DriveProvider::LANGS.length).none? do |i|
        app.window.dest_lang_selector.lang_list.get_row_at_index(i).then do |row|
          row.lang.code != "fr" && row.selection_image.get_property("visible")
        end
      end
    end
    d.check("the recent list is the provider's saved destinations") do
      app.window.dest_lang_selector.recent_list.get_row_at_index(0).lang.code == "fr"
    end
  end

  d.step("the selector's search filters the list and its rows pick a language") do
    app.window.dest_lang_selector.then do |selector|
      selector.search.text = "ger"
      pump(400)
      d.check("the search narrows the list to the matching language") do
        selector.lang_list.observe_children.n_items == 1 &&
          selector.lang_list.get_row_at_index(0).lang.code == "de"
      end
      d.check("and hides the recent list while searching") { !selector.revealer.reveal_child? }

      selector.lang_list.get_row_at_index(0).then do |row|
        selector.lang_list.signal_emit("row-activated", row)
      end
      pump(400)
      d.check("activating a row selects that language") { selector.selected == "de" }
      d.check("and relabels the button") { selector.label.label == "German" }

      selector.popover.signal_emit("closed")
      pump(300)
      d.check("closing the popover clears the search") { selector.search.text == "" }
      d.check("and reveals the recent list again") { selector.revealer.reveal_child? }
      d.check("the chosen language went to the top of the recent list") do
        selector.recent_list.get_row_at_index(0).lang.code == "de"
      end
      d.check("a case-insensitive search still matches") do
        selector.search.text = "SPAN"
        pump(300)
        selector.lang_list.observe_children.n_items == 1
      end
      d.check("a regex metacharacter is matched literally, not interpreted") do
        selector.search.text = "("
        pump(300)
        selector.lang_list.observe_children.n_items.zero?
      end
      selector.search.text = ""
      pump(300)
    end
  end

  # --- 12. the text views ---------------------------------------------------

  d.step("the two text views wrap, carry the sourceview class and share a font size") do
    d.check("both are TextViews") do
      app.window.src_text.is_a?(TextView) && app.window.dest_text.is_a?(TextView)
    end
    d.check("the source view is editable and the destination is not") do
      app.window.src_text.editable? && !app.window.dest_text.editable?
    end
    d.check("both wrap on words and characters") do
      [app.window.src_text, app.window.dest_text].all? do |view|
        view.wrap_mode.nick == "word-char"
      end
    end
    d.check("both carry the class style.css styles the caret with") do
      [app.window.src_text, app.window.dest_text].all? do |view|
        view.css_classes.include?("dialect-sourceview")
      end
    end
    d.check("both carry upstream's 9px margins") do
      [app.window.src_text, app.window.dest_text].all? do |view|
        view.left_margin == 9 && view.right_margin == 9 &&
          view.top_margin == 9 && view.bottom_margin == 9
      end
    end
    d.check("the font size starts at the system one") do
      app.window.src_text.font_size == Settings.get.system_font_size
    end
    app.window.src_text.font_size_inc
    pump(300)
    d.check("incrementing steps up by five") do
      app.window.src_text.font_size == Settings.get.system_font_size + TextView::FONT_STEP
    end
    d.check("and the destination view followed, as upstream's binding does") do
      app.window.dest_text.font_size == app.window.src_text.font_size
    end
    app.window.src_text.font_size = TextView::MIN_FONT_SIZE
    app.window.src_text.font_size_dec
    pump(300)
    d.check("decrementing refuses to go below the floor") do
      app.window.src_text.font_size == TextView::MIN_FONT_SIZE
    end
    app.window.set_font_size(Settings.get.system_font_size)
    pump(200)
    d.check("activation requires the mod key by default") { app.window.src_text.activate_mod }
    Settings.get["translate-accel"] = 1
    app.window.apply_translate_accel
    d.check("choosing plain Enter drops the mod requirement") { !app.window.src_text.activate_mod }
    Settings.get["translate-accel"] = 0
    app.window.apply_translate_accel
    d.check("and choosing Ctrl+Enter restores it") { app.window.src_text.activate_mod }
  end

  # --- 13. the window's actions and the app's accelerators ------------------

  d.step("every action upstream registers is registered, and bound") do
    %w[pronunciation preferences about quit].each do |name|
      d.check("app.#{name} is registered") { app.app.has_action?(name) }
    end
    Window::ACTIONS.each_key do |name|
      d.check("win.#{name} is registered") { app.window.window.has_action?(name) }
    end
    d.check("the pronunciation action is stateful, as upstream's is") do
      !app.app.lookup_action("pronunciation").state.nil?
    end
    Dialect::Application::ACCELS.each do |action, accels|
      d.check("#{action} is bound to #{accels.join(', ')}") do
        app.app.get_accels_for_action(action).length == accels.length
      end
    end
    d.check("nothing is bound to the text-to-speech actions, which are not ported") do
      app.app.get_accels_for_action("win.listen-src").empty? &&
        app.app.get_accels_for_action("win.listen-dest").empty?
    end
  end

  # --- 14. the source toolbar: clear, paste, counter, translate -------------

  d.step("the source toolbar counts characters and gates its actions") do
    app.window.src_text.text = ""
    pump(300)
    d.check("an empty source disables translation") do
      !app.window.window.lookup_action("translation").enabled?
    end
    d.check("and disables clear") { !app.window.window.lookup_action("clear").enabled? }
    d.check("the counter shows nothing over the limit") do
      app.window.char_counter.label == "0/#{DriveProvider::CHARS_LIMIT}"
    end
    app.window.src_text.text = "hola"
    pump(300)
    d.check("typing enables translation") do
      app.window.window.lookup_action("translation").enabled?
    end
    d.check("and enables clear") { app.window.window.lookup_action("clear").enabled? }
    d.check("the counter follows the character count") do
      app.window.char_counter.label == "4/#{DriveProvider::CHARS_LIMIT}"
    end
    app.window.src_text.text = "x" * (DriveProvider::CHARS_LIMIT + 20)
    pump(500)
    d.check("text over the provider's limit is truncated to it") do
      app.window.src_text.char_count == DriveProvider::CHARS_LIMIT
    end
    d.check("and the user is told") do
      !app.window.toast_overlay.nil? && app.window.char_counter.label ==
        "#{DriveProvider::CHARS_LIMIT}/#{DriveProvider::CHARS_LIMIT}"
    end
    app.window.window.activate_action("clear", nil)
    pump(300)
    d.check("the clear action empties the source") { app.window.src_text.text == "" }
    d.check("the clear button is wired to it") do
      app.window.clear_btn.action_name == "win.clear"
    end
    d.check("the paste button is wired to the paste action") do
      app.window.paste_btn.action_name == "win.paste"
    end
    d.check("the translate button is wired to the translation action") do
      app.window.translate_btn.action_name == "win.translation"
    end
  end

  # --- 15. a translation, its history, mistakes and pronunciation -----------

  d.step("translating fills the destination, the history and the extras") do
    app.window.src_lang_selector.selected = "en"
    app.window.dest_lang_selector.selected = "es"
    app.window.src_text.text = "hello"
    pump(300)
    app.window.window.activate_action("translation", nil)
    pump(900)
    d.check("the destination holds the provider's answer") do
      app.window.dest_text.text == "olleh"
    end
    d.check("the warning icon stays hidden") { !app.window.trans_warning.visible? }
    d.check("the spinner stopped") { !app.window.trans_spinner.visible? }
    d.check("copy is enabled now there is something to copy") do
      app.window.window.lookup_action("copy").enabled?
    end
    d.check("the translation went into the history") do
      app.window.provider("trans").history.length == 1
    end
    d.check("so going back is still disabled with only one entry") do
      !app.window.window.lookup_action("back").enabled?
    end
    d.check("the mistakes row is revealed, since the probe reports one") do
      app.window.mistakes.reveal_child?
    end
    d.check("and says what the user might have meant") do
      app.window.mistakes_label.label.include?("hello")
    end
    d.shot("05-translated")

    Settings.get.show_pronunciation = true
    app.window.check_pronunciation
    pump(300)
    d.check("the destination pronunciation is revealed when asked for") do
      app.window.dest_pron_revealer.reveal_child? &&
        app.window.dest_pron_label.label == "dest-pron"
    end
    d.check("the source one stays hidden while there is a mistake, as upstream does") do
      !app.window.src_pron_revealer.reveal_child?
    end
    Settings.get.show_pronunciation = false
    app.window.check_pronunciation
    pump(300)
    d.check("turning pronunciation off hides it again") do
      !app.window.dest_pron_revealer.reveal_child?
    end

    app.window.src_text.text = "goodbye"
    pump(300)
    app.window.window.activate_action("translation", nil)
    pump(900)
    d.check("a second translation is on top of the history") do
      app.window.provider("trans").history.length == 2
    end
    d.check("so going back is enabled") { app.window.window.lookup_action("back").enabled? }
    app.window.window.activate_action("back", nil)
    pump(500)
    d.check("going back restores the earlier source text") do
      app.window.src_text.text == "hello"
    end
    d.check("and its translation") { app.window.dest_text.text == "olleh" }
    d.check("going forward is enabled once back has been used") do
      app.window.window.lookup_action("forward").enabled?
    end
    app.window.window.activate_action("forward", nil)
    pump(500)
    d.check("going forward returns to the newer one") do
      app.window.src_text.text == "goodbye"
    end
  end

  # --- 16. switching languages ----------------------------------------------

  d.step("switching swaps the languages and the two texts") do
    app.window.src_lang_selector.selected = "en"
    app.window.dest_lang_selector.selected = "es"
    app.window.src_text.text = "one"
    app.window.dest_text.text = "two"
    pump(300)
    d.check("switch is enabled when both languages work on both sides") do
      app.window.window.lookup_action("switch").enabled?
    end
    app.window.window.activate_action("switch", nil)
    pump(500)
    d.check("the source language is now the destination one") do
      app.window.src_lang_selector.selected == "es"
    end
    d.check("and the destination language the source one") do
      app.window.dest_lang_selector.selected == "en"
    end
    d.check("the texts swapped with them") do
      app.window.src_text.text == "two" && app.window.dest_text.text == "one"
    end
    app.window.src_lang_selector.selected = "auto"
    pump(300)
    app.window.window.activate_action("switch", nil)
    pump(300)
    d.check("switching out of Auto does nothing, as upstream refuses to") do
      app.window.src_lang_selector.selected == "auto"
    end
  end

  # --- 17. suggesting a translation -----------------------------------------

  d.step("the suggestion editor opens, saves and cancels") do
    app.window.src_lang_selector.selected = "en"
    app.window.dest_lang_selector.selected = "es"
    app.window.src_text.text = "suggest me"
    pump(300)
    app.window.window.activate_action("translation", nil)
    pump(900)
    d.check("the edit button is visible, since the probe takes suggestions") do
      app.window.edit_btn.visible?
    end
    d.check("and the suggest action is enabled") do
      app.window.window.lookup_action("suggest").enabled?
    end
    app.window.window.activate_action("suggest", nil)
    pump(400)
    d.check("the destination toolbar switched to the editor") do
      app.window.dest_toolbar_stack.visible_child_name == "edit"
    end
    d.check("and the destination view became editable") { app.window.dest_text.editable? }
    app.window.dest_text.text = "my suggestion"
    app.window.window.activate_action("suggest-cancel", nil)
    pump(400)
    d.check("cancelling puts the old translation back") do
      app.window.dest_text.text == "em tseggus"
    end
    d.check("and leaves the editor") do
      app.window.dest_toolbar_stack.visible_child_name == "default" &&
        !app.window.dest_text.editable?
    end
    app.window.window.activate_action("suggest", nil)
    pump(300)
    app.window.dest_text.text = "accepted"
    app.window.window.activate_action("suggest-ok", nil)
    pump(900)
    d.check("saving a suggestion leaves the editor too") do
      app.window.dest_toolbar_stack.visible_child_name == "default"
    end
    d.check("the cancel button is wired to the cancel action") do
      app.window.cancel_btn.action_name == "win.suggest-cancel"
    end
    d.check("and the save button to the ok action") do
      app.window.save_btn.action_name == "win.suggest-ok"
    end
  end

  # --- 18. copy and paste ---------------------------------------------------

  d.step("copy puts the translation on the clipboard, paste takes text off it") do
    app.window.dest_text.text = "copy me"
    pump(300)
    app.window.window.activate_action("copy", nil)
    pump(500)
    [].then do |read|
      Gdk::Display.default.clipboard.read_text_async do |clipboard, result|
        read << clipboard.read_text_finish(result)
      end
      pump(800)
      d.check("the clipboard holds the destination text") { read.first == "copy me" }
    end
    app.window.src_text.text = ""
    pump(200)
    app.window.window.activate_action("paste", nil)
    pump(900)
    d.check("pasting appends the clipboard to the source") do
      app.window.src_text.text == "copy me"
    end
  end

  # --- 19. the keyboard shortcuts window ------------------------------------

  d.step("the shortcuts window lists upstream's shortcuts") do
    app.window.shortcuts_window.then do |dialog|
      d.check("it is an Adwaita::ShortcutsDialog") { dialog.is_a?(Adwaita::ShortcutsDialog) }
      d.check("it is titled Keyboard Shortcuts") { dialog.title == "Keyboard Shortcuts" }
      d.check("it has upstream's three groups") { ShortcutsWindow::SECTIONS.length == 3 }
      d.check("the Translate row carries the chosen accelerator") do
        dialog.translate_item.accelerator == Settings.get.translate_accel
      end
      d.check("every other row names an action, so the accelerator comes from the app") do
        ShortcutsWindow::SECTIONS.values.flat_map(&:values).all? do |action|
          action.start_with?("win.", "app.")
        end
      end
    end
    d.check("the Translator group holds the Translate row plus its actions") do
      app.window.shortcuts_window.sections.first.n_items ==
        ShortcutsWindow::SECTIONS["Translator"].length + 1
    end
    Settings.get.live_translation = true
    d.check("live translation drops the Translate row, as upstream hides it") do
      ShortcutsWindow.new(settings: Settings.get).build.then do |dialog|
        dialog.sections.first.n_items == ShortcutsWindow::SECTIONS["Translator"].length
      end
    end
    Settings.get.live_translation = false
    app.window.window.activate_action("show-help-overlay", nil)
    pump(700)
    d.check("the show-help-overlay action presents it") do
      !app.window.window.visible_dialog.nil?
    end
    d.shot("06-shortcuts")
    app.window.window.visible_dialog&.close
    pump(500)
  end

  # --- 20. the preferences dialog -------------------------------------------

  d.step("the preferences dialog mirrors upstream's three groups") do
    PreferencesDialog.new(app.window, settings: Settings.get).build.then do |prefs|
      d.check("it is an Adwaita::PreferencesDialog") { prefs.is_a?(Adwaita::PreferencesDialog) }
      d.check("the provider group holds both combo rows") do
        under?(prefs.translator_row, prefs.providers_group) &&
          under?(prefs.tts_row, prefs.providers_group)
      end
      d.check("the translator row opened on the active provider") do
        prefs.translator_row.selected_item.name == DriveProvider.provider_name
      end
      d.check("its settings button is insensitive for a provider with no settings") do
        !prefs.translator_config.sensitive?
      end
      d.check("and says so in its tooltip") do
        prefs.translator_config.tooltip_text == PreferencesDialog::NO_SETTINGS_TOOLTIP
      end
      d.check("the live translation row reflects the setting") do
        prefs.live_translation.enable_expansion? == Settings.get.live_translation
      end
      d.check("the shortcut row offers upstream's two choices") do
        prefs.translate_accel.model.n_items == 2
      end
      d.check("and opened on the saved one") do
        prefs.translate_accel.selected == Settings.get.translate_accel_value
      end
      d.check("the default-to-auto switch reflects the setting") do
        prefs.src_auto.active? == Settings.get.src_auto
      end
      d.check("the font size row is bounded by upstream's adjustment") do
        prefs.font_size_adjustment.lower == PreferencesDialog::FONT_SIZE_LOWER &&
          prefs.font_size_adjustment.upper == PreferencesDialog::FONT_SIZE_UPPER
      end

      prefs.src_auto.active = !Settings.get.src_auto
      pump(400)
      d.check("flipping a switch writes through to settings") do
        Settings.get.src_auto == prefs.src_auto.active?
      end
      prefs.src_auto.active = true
      pump(300)

      prefs.default_font_size.value = 21
      pump(400)
      d.check("changing the font size saves it") { Settings.get.default_font_size == 21 }
      d.check("and applies it to the text views") { app.window.src_text.font_size == 21 }
      app.window.set_font_size(Settings.get.system_font_size)
      pump(200)

      prefs.present(app.window.window)
      pump(800)
      d.check("the dialog presents over the window") { !app.window.window.visible_dialog.nil? }
      d.shot("07-preferences")
      app.window.window.visible_dialog&.close
      pump(500)
    end
  end

  # --- 21. the provider preferences subpage ---------------------------------

  d.step("the provider subpage shows only the settings a provider has") do
    PreferencesDialog.new(app.window, settings: Settings.get).build.then do |prefs|
      ProviderPreferences.new("trans", prefs, app.window).build.then do |page|
        d.check("it is an Adwaita::NavigationPage") { page.is_a?(Adwaita::NavigationPage) }
        d.check("its title is upstream's") { page.title == "Provider Preferences" }
        d.check("and it names the provider underneath") do
          page.window_title.subtitle == DriveProvider.prettyname
        end
        d.check("the instance row is hidden for a provider with no instances") do
          !page.instance_entry.visible?
        end
        d.check("the API key row is hidden for a provider with no key") do
          !page.api_key_entry.visible?
        end
        d.check("the usage group is hidden for a provider that reports none") do
          !page.api_usage_group.visible?
        end
        d.check("each row's suffix stack starts on its reset button") do
          page.instance_stack.visible_child_name == "reset" &&
            page.api_key_stack.visible_child_name == "reset"
        end
      end

      # A provider with instances, and one with an API key, so each row is
      # driven as it is shown.
      ProviderPreferences.new("trans", prefs, app.window).then do |page|
        page.instance_variable_set(:@provider, LibretranslateProvider.new)
        page.build
        pump(400)
        d.check("a provider with instances shows the instance row") do
          page.instance_entry.visible?
        end
        d.check("and hides the API key row it has no key for") do
          !page.api_key_entry.visible?
        end
        d.check("the instance row opened on the provider's default instance") do
          page.instance_entry.text == LibretranslateProvider.defaults[:instance_url]
        end
        page.instance_reset.signal_emit("clicked")
        pump(300)
        d.check("resetting the instance puts the default back") do
          page.instance_entry.text == LibretranslateProvider.defaults[:instance_url] &&
            !page.instance_entry.css_classes.include?("error")
        end
      end

      ProviderPreferences.new("trans", prefs, app.window).then do |page|
        page.instance_variable_set(:@provider, DeeplProvider.new)
        page.build
        pump(400)
        d.check("a provider with an API key shows the API key row") do
          page.api_key_entry.visible?
        end
        d.check("and hides the instance row it has no instances for") do
          !page.instance_entry.visible?
        end
        d.check("the settings icon the preferences buttons use resolves") do
          Gtk::IconTheme.get_for_display(Gdk::Display.default).has_icon?("dialect-settings-symbolic")
        end
      end
    end
  end

  # --- 22. the about dialog -------------------------------------------------

  d.step("the about dialog carries the metainfo's text") do
    app.about_dialog.then do |about|
      d.check("it is an Adwaita::AboutDialog") { about.is_a?(Adwaita::AboutDialog) }
      d.check("it is named Dialect") { about.application_name == "Dialect" }
      d.check("its version is the port's") { about.version == Define::VERSION }
      d.check("its summary is the metainfo's") do
        about.comments == Dialect::Application::COMMENTS
      end
      d.check("it credits the authors") do
        about.developers.to_a == Dialect::Application::DEVELOPERS
      end
      d.check("and carries the copyright line") do
        about.copyright == Dialect::Application::COPYRIGHT
      end
      d.check("it is licensed GPL-3.0-or-later, as upstream is") do
        about.license_type == Gtk::License::GPL_3_0
      end
    end
    app.app.activate_action("about", nil)
    pump(800)
    d.check("the about action presents it") { !app.window.window.visible_dialog.nil? }
    d.shot("08-about")
    app.window.window.visible_dialog&.close
    pump(500)
  end

  # --- 23. the icon assets --------------------------------------------------

  d.step("the icons upstream ships itself are on the icon theme's search path") do
    d.check("Icons reports itself loaded") { Icons.loaded? }
    d.check("a second load does nothing, so the path cannot pile up") do
      Icons.load.nil? && Icons.loaded?
    end
    d.check("both icon files are present") do
      Icons::ICON_NAMES.all? do |name|
        File.file?(File.join(Icons::SEARCH_PATH, "hicolor/scalable/emblems/#{name}.svg"))
      end
    end
    d.check("and the theme resolves both by upstream's names") { Icons.available? }
  end

  # --- 24. the command line -------------------------------------------------

  d.step("the command line options upstream takes are parsed") do
    Dialect::Application.new(argv: %w[--text hola --src en --dest es]).then do |cli|
      d.check("--text is read") { cli.argv[:text] == "hola" }
      d.check("--src is read") { cli.argv[:src] == "en" }
      d.check("--dest is read") { cli.argv[:dest] == "es" }
    end
    Dialect::Application.new(argv: %w[-n]).then do |cli|
      d.check("the short selection flag is read") { cli.argv[:selection] == true }
    end
    Dialect::Application.new(argv: %w[--nonsense]).then do |cli|
      d.check("an unknown option is ignored rather than fatal") { cli.argv.empty? }
    end
    Dialect::Application.new.then do |cli|
      d.check("no arguments means nothing to process") { cli.argv.empty? }
    end
  end

  # --- 25. translating text handed in from outside ---------------------------

  d.step("the window translates text handed to it, as the command line does") do
    app.window.translate("adios", "es", "en")
    pump(900)
    d.check("the source language came from the caller") do
      app.window.src_lang_selector.selected == "es"
    end
    d.check("the destination language too") do
      app.window.dest_lang_selector.selected == "en"
    end
    d.check("the text was translated") { app.window.dest_text.text == "soida" }
    app.window.translate("hola", nil, "de")
    pump(900)
    d.check("a nil source falls back to Auto on a detecting provider") do
      app.window.src_lang_selector.selected == "auto"
    end
    d.check("and the destination still comes from the caller") do
      app.window.dest_lang_selector.selected == "de"
    end
  end

  # --- 26. Style ------------------------------------------------------------

  d.step("the stylesheet is installed on the display") do
    d.check("Style reports itself loaded") { Style.loaded? }
    d.check("a second load does nothing, so providers do not stack") do
      Style.load.nil? && Style.loaded?
    end
    d.check("the priority is the application one") do
      Style::PRIORITY == Gtk::StyleProvider::PRIORITY_APPLICATION
    end
    d.check("upstream's empty dark sheet is carried as empty") do
      Style::DARK_STYLESHEET.strip.empty?
    end
    %w[
      translation-box translation-side-box translation-scrolled mistakes
      pronunciation search_box lang-selector themeswitcher speech-button
      dialect-sourceview
    ].each do |selector|
      d.check("the stylesheet carries .#{selector}") do
        Style::STYLESHEET.include?(".#{selector}")
      end
    end
    d.check("GTK parses the stylesheet with no errors") do
      [].then do |errors|
        Gtk::CssProvider.new.tap do |provider|
          provider.signal_connect("parsing-error") { |_p, _section, error| errors << error.message }
          provider.load(data: Style::STYLESHEET)
        end
        errors.empty?
      end
    end
  end

  # --- 27. Define -----------------------------------------------------------

  d.step("the build-time constants match upstream's define.in") do
    d.check("the app id") { Define::APP_ID == "app.drey.Dialect" }
    d.check("the resource path") { Define::RES_PATH == "/app/drey/Dialect" }
    d.check("the version") { Define::VERSION == "2.6.0" }
    d.check("the history length") { Define::TRANS_NUMBER == 10 }
    d.check("the profile comes from the environment") { Define::PROFILE == ENV.fetch("DIALECT_PROFILE", "") }
    d.check("the CLDR table is populated") { Define::LANGUAGES.length > 600 }
    d.check("every alias target is itself a known language") do
      Define::LANG_ALIASES.values.all? { |code| Define::LANGUAGES.key?(code) }
    end
    d.check("the aliases cover upstream's five") do
      Define::LANG_ALIASES.keys.sort == ["iw", "jw", "mni-Mtei", "zh-CN", "zh-TW"]
    end
  end

  # --- 28. Utils ------------------------------------------------------------

  d.step("the list helpers behave like upstream's") do
    d.check("find_item_match takes the first of list1 in list2") do
      Utils.find_item_match(%w[de fr es], %w[es fr]) == "fr"
    end
    d.check("find_item_match is nil when nothing is shared") do
      Utils.find_item_match(%w[de], %w[es fr]).nil?
    end
    d.check("find_item_match on an empty list is nil") do
      Utils.find_item_match([], %w[es]).nil?
    end
    d.check("first_exclude skips the excluded item") do
      Utils.first_exclude(%w[en fr], "en") == "fr"
    end
    d.check("first_exclude is nil when everything is excluded") do
      Utils.first_exclude(%w[en en], "en").nil?
    end
  end

  # --- 29. the provider error hierarchy -------------------------------------

  d.step("the provider errors keep upstream's hierarchy") do
    d.check("RequestError is deliberately not a ProviderError") do
      !RequestError.ancestors.include?(ProviderError)
    end
    [
      UnexpectedError, APIKeyRequired, APIKeyInvalid, InvalidLangCode,
      BatchSizeExceeded, CharactersLimitExceeded, ServiceLimitReached,
    ].each do |klass|
      d.check("#{klass} is a ProviderError") { klass.ancestors.include?(ProviderError) }
    end
    d.check("ResponseError carries the cause message") do
      ResponseError.new("socket broke").then do |exc|
        exc.cause_message == "socket broke" && exc.message.include?("Response has failed")
      end
    end
  end

  # --- 30. Languages, 31. LangObject, 32. LanguagesListModel ---------------

  d.step("the language model fills, reorders and tracks the selection") do
    d.check("lang_name resolves a CLDR code") { Languages.lang_name("fr") == "French" }
    d.check("lang_name is nil for a code CLDR has none for") { Languages.lang_name("zzz").nil? }

    LanguagesListModel.new.then do |model|
      d.check("a fresh model is empty") { model.n_items.zero? }

      [].then do |emissions|
        model.model.signal_connect("items-changed") { |_m, pos, removed, added| emissions << [pos, removed, added] }

        model.set_langs(%w[en fr de])
        d.check("set_langs fills the model") { model.n_items == 3 }
        d.check("it emitted one items-changed") { emissions.length == 1 }
        d.check("and reported the whole replacement in it") { emissions.first == [0, 0, 3] }

        model.set_langs(%w[es it], auto: true)
        d.check("auto puts an Auto row first") { model[0].code == "auto" && model[0].name == "Auto" }
        d.check("the replacement was one emission too") { emissions.length == 2 }
        d.check("which removed all three and added three") { emissions.last == [0, 3, 3] }
      end

      d.check("a LangObject carries code and CLDR name") do
        model[1].code == "es" && model[1].name == "Spanish"
      end
      d.check("a code with no CLDR name falls back to the code") do
        LanguagesListModel.new.tap { |m| m.set_langs(%w[zzz]) }[0].name == "zzz"
      end

      [].then do |notified|
        model[1].signal_connect("notify::selected") { notified << model[1].code }
        model.set_selected("es")
        d.check("set_selected marks the matching lang") { model[1].selected }
        d.check("and nothing else") { model.langs.count(&:selected) == 1 }
        d.check("it notified the row so it can redraw its tick") { notified == ["es"] }
      end

      d.check("set_selected on an unknown code selects nothing") do
        model.set_selected("nope")
        model.langs.none?(&:selected)
      end
      d.check("LangObject#to_s is its code") { model[1].to_s == "es" }
      d.check("the model is a real Gio::ListModel for widgets") { model.model.is_a?(Gio::ListModel) }
    end
  end

  # --- 33. Providers registry ---------------------------------------------

  d.step("every provider upstream ships is registered") do
    d.check("all seven modules are loaded") do
      (Providers::MODULES.keys - [DriveProvider.provider_name]) ==
        %w[bing deepl google kagi libretranslate lingva yandex]
    end
    d.check("all seven translate") do
      (Providers::TRANSLATORS.keys - [DriveProvider.provider_name]).length == 7
    end
    d.check("google and lingva are the TTS providers") do
      Providers::TTS.keys == %w[google lingva]
    end
    d.check("lookup by name returns the class") { Providers["deepl"] == DeeplProvider }
    d.check("lookup of an unknown name is nil") { Providers["nope"].nil? }
    d.check("google is available") { Providers.check_translator_availability("google") }
    d.check("a withdrawn provider is not") { !Providers.check_translator_availability("babelfish") }
    d.check("the fallback is the first registered translator") do
      Providers.fallback_translator_name == "bing"
    end
  end

  # --- 34. ProviderObject, 35. ProvidersListModel -------------------------

  d.step("the provider dropdown models list the right providers") do
    ProvidersListModel.new("translators").then do |model|
      d.check("the translators list holds seven, plus this script's probe") do
        model.n_items == 8 && model.get_index_by_name(DriveProvider.provider_name).positive?
      end
      d.check("the first is Bing") { model[0].name == "bing" && model[0].prettyname == "Bing" }
      d.check("prettynames come off the provider class") do
        model.providers.map(&:prettyname).include?("Kagi Translate")
      end
      d.check("get_index_by_name finds a provider") { model.get_index_by_name("google") == 2 }
      d.check("an unknown name falls back to position 0") { model.get_index_by_name("nope").zero? }
      d.check("the model is a real Gio::ListModel") { model.model.is_a?(Gio::ListModel) }
      d.check("its items are ProviderObjects") { model[0].is_a?(ProviderObject) }
      d.check("the name property is readable through GObject") do
        model[0].get_property("name") == "bing"
      end
      d.check("so is prettyname") { model[0].get_property("prettyname") == "Bing" }
    end

    ProvidersListModel.new("tts", show_disabled: true).then do |model|
      d.check("the TTS list adds a Disabled row") { model.n_items == 3 }
      d.check("Disabled is first") { model[0].prettyname == Providers::DISABLED_NAME }
      d.check("and has no name") { model[0].name.empty? }
      d.check("and no provider class behind it") { model[0].provider_class.nil? }
      d.check("then google and lingva") { model.providers.drop(1).map(&:name) == %w[google lingva] }
    end

    d.check("an unrecognised type lists every module") do
      ProvidersListModel.new("everything").n_items == Providers::MODULES.length
    end
  end

  # --- 36. Settings -------------------------------------------------------

  d.step("settings round-trip through the file on disk") do
    File.join(SCRATCH, "roundtrip.json").then do |path|
      Settings.new(path: path).then do |settings|
        d.check("defaults match the gschema window size") { settings["window-size"] == [800, 300] }
        d.check("color-scheme defaults to auto") { settings.color_scheme == "auto" }
        d.check("live-translation defaults off") { settings.live_translation == false }
        d.check("sp-translation defaults off") { settings.sp_translation == false }
        d.check("show-pronunciation defaults off") { settings.show_pronunciation == false }
        d.check("src-auto defaults on") { settings.src_auto == true }
        d.check("custom-default-font-size defaults off") { settings.custom_default_font_size == false }
        d.check("default-font-size defaults to 0") { settings.default_font_size.zero? }
        d.check("the translators list starts empty") { settings.translators_list == [] }
        d.check("the active translator defaults to google") { settings.active_translator == "google" }
        d.check("the active TTS defaults to google") { settings.active_tts == "google" }

        settings.live_translation = true
        settings.show_pronunciation = true
        settings.color_scheme = "dark"
        settings.window_size = [1024, 600]
        settings.default_font_size = 14
        settings.translators_list = %w[google deepl]
        settings.active_translator = "deepl"

        d.check("the file was written") { File.exist?(path) }

        Settings.new(path: path).then do |reread|
          d.check("live-translation came back") { reread.live_translation == true }
          d.check("show-pronunciation came back") { reread.show_pronunciation == true }
          d.check("color-scheme came back") { reread.color_scheme == "dark" }
          d.check("the window size came back") { reread.window_size == [1024, 600] }
          d.check("the font size came back") { reread.default_font_size == 14 }
          d.check("the translators list came back") { reread.translators_list == %w[google deepl] }
          d.check("the active translator came back") { reread.active_translator == "deepl" }
        end
      end
    end
  end

  d.step("settings heal a stale provider and notify observers") do
    File.join(SCRATCH, "heal.json").then do |path|
      File.write(
        path,
        JSON.generate(
          {
            "translators" => {"active" => "babelfish"},
            "tts"         => {"active" => "espeak"},
          },
        ),
      )

      Settings.new(path: path).then do |settings|
        d.check("an unloaded translator falls back to the first loaded one") do
          settings.active_translator == "bing"
        end
        d.check("the healed value was written back") do
          JSON.parse(File.read(path))["translators"]["active"] == "bing"
        end
        d.check("an unloaded TTS provider is cleared") { settings.active_tts == "" }
        d.check("an empty TTS provider stays empty") { settings.active_tts == "" }

        [].then do |changes|
          settings.on_provider_changed { |kind, name| changes << [kind, name] }
          settings.active_translator = "google"
          settings.active_tts = "lingva"
          d.check("both changes reached the observer") do
            changes == [["translator", "google"], ["tts", "lingva"]]
          end
        end
      end
    end
  end

  d.step("settings survive a corrupt file and map the translate accel") do
    File.join(SCRATCH, "corrupt.json").then do |path|
      File.write(path, "{ this is not json")
      Settings.new(path: path).then do |settings|
        d.check("a corrupt file falls back to the defaults") { settings.window_size == [800, 300] }
        d.check("Ctrl+Enter is accel 0") { settings.translate_accel == "<Primary>Return" }
        settings["translate-accel"] = 1
        d.check("plain Enter is accel 1") { settings.translate_accel == "Return" }
        settings["translate-accel"] = 99
        d.check("anything else falls back to Ctrl+Enter") { settings.translate_accel == "<Primary>Return" }
        d.check("the raw value is readable") { settings.translate_accel_value == 99 }
        d.check("the system font size is a sane number") { settings.system_font_size.positive? }
      end
    end
    d.check("Settings.get is process-wide") { Settings.get.equal?(Settings.get) }
    d.check("and the app used it") { app.settings.equal?(Settings.get) }
  end

  # --- 37. ProviderSettings -----------------------------------------------

  d.step("per-provider settings read, write and migrate the API key") do
    File.join(SCRATCH, "provider-settings.json").then do |settings_path|
      File.join(SCRATCH, "secrets.json").then do |secrets_path|
        Settings.new(path: settings_path).then do |settings|
          LibretranslateProvider.defaults.then do |defaults|
            ProviderSettings.new("libretranslate", defaults, settings: settings, secrets_path: secrets_path).then do |ps|
              d.check("init starts false") { ps.init == false }
              ps.init = true
              d.check("init was written") { ps.init == true }

              d.check("instance_url falls back to the provider's own default") do
                ps.instance_url == "lt.dialectapp.org"
              end
              ps.instance_url = "translate.example.org"
              d.check("a set instance url wins") { ps.instance_url == "translate.example.org" }
              ps.instance_url = ""
              d.check("clearing it restores the default") { ps.instance_url == defaults[:instance_url] }

              d.check("src_langs fall back to the provider defaults") do
                ps.src_langs == defaults[:src_langs]
              end
              ps.src_langs = %w[nl pl]
              d.check("recent src langs were saved") { ps.src_langs == %w[nl pl] }
              ps.dest_langs = %w[pt]
              d.check("recent dest langs were saved") { ps.dest_langs == %w[pt] }

              [].then do |keyed|
                ps.on_api_key_changed { |name| keyed << name }
                ps.api_key = "s3cret"
                d.check("the key is readable") { ps.api_key == "s3cret" }
                d.check("the observer fired") { keyed == ["libretranslate"] }
                d.check("it went to the secrets file, not settings") do
                  JSON.parse(File.read(secrets_path))["libretranslate"] == "s3cret" &&
                    !File.read(settings_path).include?("s3cret")
                end
                d.check("the secrets file is owner-only") do
                  (File.stat(secrets_path).mode & 0o777) == 0o600
                end
                ps.api_key = ""
                d.check("clearing drops it from the secrets file") do
                  !JSON.parse(File.read(secrets_path)).key?("libretranslate")
                end
                d.check("and the key reads back as the default") { ps.api_key == defaults[:api_key] }
              end
            end

            # A key left in settings by an older release migrates on first read.
            settings.provider_set("libretranslate", "api-key", "legacy-key")
            ProviderSettings.new(
              "libretranslate",
              defaults,
              settings:     settings,
              secrets_path: secrets_path,
            ).then do |fresh|
              d.check("a legacy settings key is still readable") { fresh.api_key == "legacy-key" }
              d.check("it moved into the secrets file") do
                JSON.parse(File.read(secrets_path))["libretranslate"] == "legacy-key"
              end
              d.check("and was cleared from settings") do
                settings.provider_section("libretranslate")["api-key"] == ""
              end
            end
          end
        end
      end
    end
  end

  # --- 38. Provider base --------------------------------------------------

  d.step("the provider base class composes urls and normalizes lang codes") do
    d.check("format_url builds an https url") do
      Provider.format_url("example.org", "api") == "https://example.org/api"
    end
    d.check("a missing leading slash is added") do
      Provider.format_url("example.org", "a/b") == "https://example.org/a/b"
    end
    d.check("params are query-encoded") do
      Provider.format_url("example.org", "/t", {q: "a b"}) == "https://example.org/t?q=a+b"
    end
    d.check("no params means no question mark") do
      !Provider.format_url("example.org", "/t").include?("?")
    end
    d.check("http: true forces http") do
      Provider.format_url(
        "example.org",
        "",
        {},
        http: true,
      ).start_with?("http://")
    end
    d.check("localhost is always http") do
      Provider.format_url("localhost:5000", "/x").start_with?("http://")
    end

    Provider.new.then do |provider|
      d.check("codes are lowercased") { provider.normalize_lang_code("ES") == "es" }
      d.check("underscores become hyphens") { provider.normalize_lang_code("pt_BR") == "pt-BR" }
      d.check("a two-char subtag is upcased") { provider.normalize_lang_code("pt-br") == "pt-BR" }
      d.check("a four-char subtag is capitalized") { provider.normalize_lang_code("zh-HANS") == "zh-Hans" }
      d.check("Define's aliases are applied") { provider.normalize_lang_code("iw") == "he" }
      d.check("an alias with a subtag is applied") { provider.normalize_lang_code("zh_CN") == "zh-Hans" }

      provider.add_lang("pt_BR", "Brazilian")
      provider.add_lang("iw", "Hebrew", trans_dest: false, tts: true)
      provider.add_lang("fr", nil, trans_src: false)
      d.check("add_lang fills src_languages") { provider.src_languages == %w[pt-BR he] }
      d.check("add_lang fills dest_languages") { provider.dest_languages == %w[pt-BR fr] }
      d.check("add_lang fills tts_languages") { provider.tts_languages == %w[he] }
      d.check("denormalize_lang gives the provider's own code back") do
        provider.denormalize_lang("he", "pt-BR") == %w[iw pt_BR]
      end
      d.check("a code that was never renamed passes through") do
        provider.denormalize_lang("fr") == %w[fr]
      end
      d.check("get_lang_name prefers CLDR") { provider.get_lang_name("pt-BR") == "Brazilian Portuguese" }
      d.check("and falls back to the provider's own name") do
        provider.add_lang("xx-yy", "Madeup")
        provider.get_lang_name("xx-YY") == "Madeup"
      end
      d.check("and ultimately to the code") { provider.get_lang_name("qqq") == "qqq" }

      d.check("the base class declares no capabilities") { provider.capabilities.zero? }
      d.check("so it neither translates nor speaks nor defines") do
        !provider.translates? && !provider.speaks? && !provider.defines?
      end
      d.check("the base lang model is static") { provider.lang_model == ProviderLangModel::STATIC }
      d.check("the base comparison is plain") { provider.lang_comp == ProviderLangComparison::PLAIN }
      d.check("plain cmp_langs only matches whole codes") do
        provider.cmp_langs("pt-BR", "pt-BR") && !provider.cmp_langs("pt-BR", "pt")
      end
      d.check("chars_limit starts at -1") { provider.chars_limit == -1 }
      d.check("history starts empty") { provider.history.empty? }

      d.check("the base class starts with no features") { provider.features.zero? }
      d.check("add_feature turns a feature on") do
        provider.add_feature(ProviderFeature::INSTANCES)
        provider.supports_instances?
      end
      d.check("adding it twice does not turn it back off") do
        provider.add_feature(ProviderFeature::INSTANCES)
        provider.supports_instances?
      end

      [
        [:init_trans, -> { provider.init_trans }],
        [:init_tts, -> { provider.init_tts }],
        [:translate, -> { provider.translate(TranslationRequest.new(text: "x", src: "en", dest: "fr")) }],
        [:speech, -> { provider.speech("x", "en") }],
        [:suggest, -> { provider.suggest(
          "x",
          "en",
          "fr",
          "y",
        ) }
],
        [:validate_instance, -> { provider.validate_instance("example.org") }],
        [:validate_api_key, -> { provider.validate_api_key("k") }],
        [:api_char_usage, -> { provider.api_char_usage }],
        [:dest_langs_for, -> { provider.dest_langs_for("en") }],
      ].each do |(name, call)|
        d.check("the base ##{name} refuses with NotImplementedError") do
          raised_by(&call).is_a?(NotImplementedError)
        end
      end
    end

    DeeplProvider.new.then do |deep|
      d.check("a DEEP provider matches on the base code") do
        deep.cmp_langs("pt-BR", "pt") && deep.cmp_langs("pt", "pt-BR")
      end
      d.check("but still not across languages") { !deep.cmp_langs("pt-BR", "fr") }
    end
  end

  d.step("the translation data objects carry upstream's fields") do
    TranslationRequest.new(text: "hola", src: "es", dest: "en").then do |request|
      d.check("a request carries text, src and dest") do
        request.text == "hola" && request.src == "es" && request.dest == "en"
      end
    end
    TranslationPronunciation.new.then do |pron|
      d.check("a pronunciation defaults to neither side") { pron.src.nil? && pron.dest.nil? }
    end
    Translation.new(text: "hello", original: "hola").then do |translation|
      d.check("a translation carries the text and the original") do
        translation.text == "hello" && translation.original == "hola"
      end
      d.check("detected and mistakes default to nil") do
        translation.detected.nil? && translation.mistakes.nil?
      end
      d.check("and it gets an empty pronunciation") do
        translation.pronunciation.is_a?(TranslationPronunciation)
      end
    end
    TranslationMistake.new(markup: "<b>x</b>", text: "x").then do |mistake|
      d.check("a mistake carries markup and plain text") do
        mistake.markup == "<b>x</b>" && mistake.text == "x"
      end
    end
  end

  # --- 39-45. the seven provider classes ----------------------------------

  d.step("each ported provider declares what upstream's module declares") do
    {
      BingProvider           => ["bing", "Bing", ProviderCapability::TRANSLATION, ProviderLangComparison::PLAIN],
      DeeplProvider          => ["deepl", "DeepL", ProviderCapability::TRANSLATION, ProviderLangComparison::DEEP],
      GoogleProvider         => ["google", "Google",
                         ProviderCapability::TRANSLATION | ProviderCapability::TTS,
                         ProviderLangComparison::PLAIN,
],
      KagiProvider           => ["kagi", "Kagi Translate", ProviderCapability::TRANSLATION, ProviderLangComparison::DEEP],
      LibretranslateProvider => ["libretranslate", "LibreTranslate",
                                 ProviderCapability::TRANSLATION, ProviderLangComparison::PLAIN,
],
      LingvaProvider         => ["lingva", "Lingva Translate",
                         ProviderCapability::TRANSLATION | ProviderCapability::TTS,
                         ProviderLangComparison::PLAIN,
],
      YandexProvider         => ["yandex", "Yandex", ProviderCapability::TRANSLATION, ProviderLangComparison::DEEP],
    }.each do |klass, (name, pretty, capabilities, comparison)|
      d.check("#{name} names itself") { klass.provider_name == name }
      d.check("#{name} has the display name #{pretty}") { klass.prettyname == pretty }
      d.check("#{name} declares its capabilities") { klass.capabilities == capabilities }
      d.check("#{name} compares langs #{comparison}") { klass.lang_comp == comparison }
      d.check("#{name} registered itself under its own name") { Providers[name] == klass }
      d.check("#{name} instantiates with its own settings section") do
        klass.new.then do |provider|
          provider.provider_name == name &&
            provider.settings.is_a?(ProviderSettings) &&
            provider.settings.name == name &&
            provider.settings.defaults.equal?(klass.defaults)
        end
      end
      d.check("#{name} declares all four default keys") do
        klass.defaults.keys.sort == %i[api_key dest_langs instance_url src_langs]
      end
      d.check("#{name} translates") { klass.new.translates? }
    end

    d.check("LibreTranslate is the instances provider") do
      LibretranslateProvider.new.supports_instances?
    end
    d.check("DeepL requires an API key") { DeeplProvider.new.api_key_required? }
    d.check("Bing reports pronunciations") { BingProvider.new.supports_pronunciation? }
    d.check("Yandex detects the source language") { YandexProvider.new.supports_detection? }
    d.check("Google speaks") { GoogleProvider.new.speaks? }
    d.check("Lingva speaks") { LingvaProvider.new.speaks? }
    d.check("Kagi does not speak") { !KagiProvider.new.speaks? }
  end

  # --- 46. Session --------------------------------------------------------

  d.step("the HTTP session talks to a real socket") do
    Session.new.then do |session|
      session.send_and_read("GET", PROBE.url("/json")).then do |response|
        d.check("a GET comes back 200") { response.status == 200 }
        d.check("with the body") { JSON.parse(response.body)["ok"] == true }
      end
      d.check("a plain-text body comes back raw") do
        session.send_and_read("GET", PROBE.url("/text")).body == "plain words"
      end
      d.check("an empty body comes back empty") do
        session.send_and_read("GET", PROBE.url("/empty")).body.empty?
      end
      d.check("a 404 is reported, not raised") do
        session.send_and_read("GET", PROBE.url("/nowhere")).status == 404
      end
      d.check("the Dialect User-Agent is sent") do
        JSON.parse(session.send_and_read("GET", PROBE.url("/agent")).body)["agent"] == Session::USER_AGENT
      end
      d.check("a caller's own User-Agent is not overwritten") do
        session.send_and_read("GET", PROBE.url("/agent"), headers: {"User-Agent" => "Mine/1"}).then do |r|
          JSON.parse(r.body)["agent"] == "Mine/1"
        end
      end
      d.check("a POST sends a JSON body by default") do
        session.send_and_read("POST", PROBE.url("/echo"), data: {"a" => 1}).then do |r|
          JSON.parse(r.body).then do |echo|
            echo["type"] == "application/json" && JSON.parse(echo["body"]) == {"a" => 1}
          end
        end
      end
      d.check("form: true sends a form body") do
        session.send_and_read("POST", PROBE.url("/echo"), data: {"a" => "b c"}, form: true).then do |r|
          JSON.parse(r.body).then do |echo|
            echo["type"].start_with?("application/x-www-form-urlencoded") && echo["body"] == "a=b+c"
          end
        end
      end
      d.check("a 308 keeps the method and body") do
        session.send_and_read("POST", PROBE.url("/moved-keep"), data: {"a" => 1}).then do |r|
          JSON.parse(r.body).then { |echo| echo["method"] == "POST" && !echo["body"].empty? }
        end
      end
      d.check("a 302 rewrites the request to a GET and drops the body") do
        session.send_and_read("POST", PROBE.url("/moved-get"), data: {"a" => 1}).then do |r|
          JSON.parse(r.body).then { |echo| echo["method"] == "GET" && echo["body"].empty? }
        end
      end
      d.check("a redirect loop stops at the hop budget") do
        PROBE.hits("/moved-loop").then do |before|
          session.send_and_read("GET", PROBE.url("/moved-loop")).status == 308 &&
            (PROBE.hits("/moved-loop") - before) == Session::MAX_REDIRECTS + 1
        end
      end
      d.check("a malformed url becomes a ResponseError") do
        raised_by { session.send_and_read("GET", "http://[bad") }.is_a?(ResponseError)
      end
      d.check("a refused connection becomes a ResponseError") do
        raised_by { session.send_and_read("GET", "http://127.0.0.1:#{REFUSED_PORT}/x") }.is_a?(ResponseError)
      end
    end
    d.check("Session.get is process-wide") { Session.get.equal?(Session.get) }
    d.check("Session.reset drops it") do
      Session.get.then do |first|
        Session.reset
        !Session.get.equal?(first)
      end
    end
  end

  # --- 47. SessionHelpers -------------------------------------------------

  d.step("the provider request helpers retry, parse and raise") do
    DeniedProbe.new.then do |probe|
      d.check("#get parses JSON by default") { probe.get(PROBE.url("/json"))["ok"] == true }
      d.check("return_json: false hands back the raw body") do
        probe.get(PROBE.url("/text"), return_json: false) == "plain words"
      end
      d.check("an empty body parses to an empty hash") { probe.get(PROBE.url("/empty")) == {} }
      d.check("#post posts") { probe.post(PROBE.url("/echo"), data: {"a" => 1})["method"] == "POST" }
      d.check("a provider's own error check raises its exception") do
        raised_by { probe.get(PROBE.url("/denied")) }.is_a?(APIKeyInvalid)
      end
      d.check("check_common: false skips that check") do
        probe.get(PROBE.url("/denied"), check_common: false)["error"] == "bad key"
      end
      d.check("a transport failure becomes a RequestError") do
        raised_by { probe.get("http://127.0.0.1:#{REFUSED_PORT}/x") }.is_a?(RequestError)
      end
      d.check("the base check_known_errors accepts everything") do
        Provider.new.get(PROBE.url("/denied"))["error"] == "bad key"
      end
    end

    RetryProbe.new.then do |probe|
      PROBE.hits("/flaky").then do |before|
        d.check("a retryable status is retried until it clears") do
          probe.get(PROBE.url("/flaky"))["ok"] == true
        end
        d.check("which took more than one request") { (PROBE.hits("/flaky") - before) >= 2 }
      end
      d.check("the default policy retries nothing") { Provider.new.retry_errors.empty? }
      d.check("the default budget is upstream's five") { Provider.new.max_retries == 5 }
    end
  end

  # --- 48. BackgroundTask -------------------------------------------------

  d.step("background work is delivered back on the main loop") do
    [].then do |results|
      Thread.current.then do |main|
        BackgroundTask.run(on_success: ->(value) { results << [value, Thread.current.equal?(main)] }) do
          "worked"
        end
        pump(800)
        d.check("the success callback ran") { results.length == 1 }
        d.check("with the block's value") { results.dig(0, 0) == "worked" }
        d.check("on the main thread, where widgets are safe to touch") { results.dig(0, 1) == true }
      end
    end

    [].then do |errors|
      BackgroundTask.run(on_error: ->(exc) { errors << exc }) { raise APIKeyRequired, "no key" }
      pump(800)
      d.check("a raise reaches the error callback") { errors.length == 1 }
      d.check("as the exception itself") { errors.first.is_a?(APIKeyRequired) }
      d.check("with its message") { errors.first.message == "no key" }
    end

    [].then do |results|
      BackgroundTask.new(on_success: ->(value) { results << value }) { "ignored" }.then do |task|
        task.cancel
        task.start
        pump(800)
        d.check("a cancelled task delivers nothing") { results.empty? }
        d.check("and reports itself cancelled") { task.cancelled? }
      end
    end

    [].then do |results|
      BackgroundTask.new(on_success: ->(value) { results << value }) { 6 * 7 }.then do |task|
        task.start.wait
        d.check("#wait delivers inline for callers with no loop") { results == [42] }
        d.check("and the task is no longer pending") { !task.pending? }
      end
    end

    [].then do |results|
      BackgroundTask.run(on_success: ->(value) { results << value }) { "once" }.then do |task|
        pump(600)
        task.wait
        d.check("the outcome is delivered exactly once") { results == ["once"] }
      end
    end

    d.check("a task with no error callback re-raises rather than swallowing") do
      BackgroundTask.new { raise "boom" }.then do |task|
        raised_by { task.start.wait }.is_a?(RuntimeError)
      end
    end
  end

  # --- what the port does NOT yet have ------------------------------------
  #
  # Asserted explicitly so this script cannot be mistaken for covering more of
  # upstream than it does. Each of these is named in `remaining` in the port's
  # notes, with the reason, and these checks fail the moment one of them lands
  # without being driven.

  d.step("the components this round leaves out are absent, not half-built") do
    # Text-to-speech: no Gst typelib in the dev shell, so there is nothing to
    # play a provider's audio with.
    %w[listen-src listen-dest].each do |name|
      d.check("win.#{name} is not registered") { !app.window.window.has_action?(name) }
    end
    d.check("there is no speech button class") { !Object.const_defined?(:SpeechButton) }
    d.check("and no speech button in the source toolbar") do
      app.window.src_toolbar.observe_children.then do |children|
        Array.new(children.n_items) { |i| children.get_item(i) }
             .none? { |child| child.css_classes.include?("speech-button") }
      end
    end
    d.check("the broken-speakers icon is carried anyway, for when it lands") do
      Gtk::IconTheme.get_for_display(Gdk::Display.default)
                    .has_icon?("dialect-speakers-broken-symbolic")
    end
  end

  # --- the GNOME Shell search provider ------------------------------------
  #
  # Driven against the registered DriveProvider, offline, exactly as every
  # other provider-backed step in this script is: no real search provider
  # process, no real D-Bus connection (that is proven separately, against a
  # real session bus, in test/drive_search_provider_dbus.rb-shaped runs — see
  # lib/search_provider.rb's class comment), just the Ruby object's own
  # methods.
  d.step("the GNOME Shell search provider answers searches") do
    search_provider = SearchProvider.new(binary: "true")

    d.check("GetInitialResultSet prompts when live search is off") do
      search_provider.initial_result_set(["hi"]) == ["Translate “hi” with Drive Probe"]
    end

    Settings.get.live_translation = true
    Settings.get.sp_translation = true

    d.check("GetInitialResultSet translates once live search is on") do
      search_provider.initial_result_set(["hello"]) == ["hello", "copy-to-clipboardhello"]
    end
    d.check("the translation came back reversed, from DriveProvider") do
      search_provider.result_metas(["hello"]).first.fetch("name") == "olleh"
    end
    d.check("GetResultMetas on the pair also returns the clipboard row") do
      metas = search_provider.result_metas(["hello", "copy-to-clipboardhello"])
      metas.length == 2 && metas.last.fetch("clipboardText") == "olleh"
    end
    d.check("GetSubsearchResultSet re-runs the same search") do
      search_provider.subsearch_result_set([], ["hello"]) == ["hello", "copy-to-clipboardhello"]
    end
    d.check("the interface info resolves through lookup_interface") do
      search_provider.interface_info.name == "org.gnome.Shell.SearchProvider2"
    end

    Settings.get.live_translation = false
    Settings.get.sp_translation = false
  end

  d.step("the translation catalogs are checked out") do
    po_dir = File.expand_path("../po", __dir__)
    d.check("po/ exists") { Dir.exist?(po_dir) }
    d.check("the CLDR language catalog is there") { Dir.exist?(File.join(po_dir, "cldr-langs")) }
  end

  # --- 49. the window's close-request handler -----------------------------
  #
  # Last, because emitting close-request runs GTK's own default handler too,
  # which takes the window down.

  d.step("closing the window writes the size back to settings") do
    d.shot("04-before-close")
    Settings.get.window_size = [100, 100]
    # Inside the 640x480 virtual display, again so GTK does not clamp it.
    app.window.window.set_default_size(620, 455)
    pump(300)
    app.window.window.signal_emit("close-request").then do |stopped|
      d.check("the handler does not veto the close") { stopped == false }
    end
    d.check("the size was persisted") { Settings.get.window_size == [620, 455] }
    d.check("and reached the file on disk") do
      JSON.parse(File.read(Settings.get.path))["window-size"] == [620, 455]
    end
  end
end

PROBE.stop
