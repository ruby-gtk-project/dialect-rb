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
  attr_reader :port, :log

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @log = []
    @hits = Hash.new(0)
    @mutex = Mutex.new
    @thread = Thread.new { accept_loop }
  end

  def url(path) = "http://127.0.0.1:#{port}#{path}"

  def hits(path) = @mutex.synchronize { @hits[path] }
  def requests = @mutex.synchronize { @log.dup }

  def stop
    @thread.kill
    @server.close
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
        @mutex.synchronize do
          @hits[path] += 1
          @log << {method: method, path: path, headers: headers, body: body}
        end

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
        if @hits["/flaky"] < 2
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
  d.window { app.window }

  # --- 1. the window, 2. the toolbar view, 3. the header bar ---------------

  d.step("the application window builds") do
    d.check("the application is a Gtk::Application") { app.app.is_a?(Gtk::Application) }
    d.check("its id is the reverse-dns app id") do
      app.app.application_id == "org.rubygtkproject.Dialect"
    end
    d.check("libadwaita was initialized, so Adwaita widgets get their style") do
      Adwaita.initialized?
    end
    d.check("the Adwaita style manager is reachable") do
      !Adwaita::StyleManager.default.nil?
    end
    d.check("the window is an Adwaita::ApplicationWindow") do
      app.window.is_a?(Adwaita::ApplicationWindow)
    end
    d.check("it is the only toplevel") { Gtk::Window.list_toplevels.length == 1 }
    d.check("it belongs to the application") { app.app.windows.length == 1 }
    d.check("its title is dialect") { app.window.title == "dialect" }
    d.check("it is visible") { app.window.visible? }
    d.check("it restored the window size from settings") do
      [app.window.default_width, app.window.default_height] == WINDOW_SIZE
    end
    d.check("the toolbar view is an Adwaita::ToolbarView") do
      app.toolbar_view.is_a?(Adwaita::ToolbarView)
    end
    d.check("the toolbar view is the window content") do
      app.window.content.equal?(app.toolbar_view)
    end
    d.check("the header bar is an Adwaita::HeaderBar") do
      app.header_bar.is_a?(Adwaita::HeaderBar)
    end
    d.check("the header bar is packed into the toolbar view") do
      under?(app.header_bar, app.toolbar_view)
    end
    d.check("the header bar shows the window title") { app.header_bar.show_title? }
    d.shot("01-main-window")
  end

  # --- 4. the status page (the port's only content state) -----------------

  d.step("the status page is the content, and says what is ported") do
    d.check("the status page is an Adwaita::StatusPage") do
      app.status_page.is_a?(Adwaita::StatusPage)
    end
    d.check("it is the toolbar view's content") do
      app.toolbar_view.content.equal?(app.status_page)
    end
    d.check("its title is dialect") { app.status_page.title == "dialect" }
    d.check("its icon is set") do
      app.status_page.icon_name == "applications-engineering-symbolic"
    end
    d.check("the icon theme resolves that icon") do
      Gtk::IconTheme.get_for_display(Gdk::Display.default).has_icon?(app.status_page.icon_name)
    end
    d.check("its description counts the ported providers") do
      app.status_page.description.start_with?("#{Providers::TRANSLATORS.length} translation providers are ported")
    end
    d.check("there are seven of them") { Providers::TRANSLATORS.length == 7 }
    d.check("it says the translation window is not ported") do
      app.status_page.description.include?("The translation window is not.")
    end
    d.shot("02-status-page")
  end

  # --- 5. Style ------------------------------------------------------------

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

  # --- 6. Define -----------------------------------------------------------

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

  # --- 7. Utils ------------------------------------------------------------

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

  # --- 8. the provider error hierarchy -------------------------------------

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

  # --- 9. Languages, 10. LangObject, 11. LanguagesListModel ---------------

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

  # --- 12. Providers registry ---------------------------------------------

  d.step("every provider upstream ships is registered") do
    d.check("all seven modules are loaded") do
      Providers::MODULES.keys == %w[bing deepl google kagi libretranslate lingva yandex]
    end
    d.check("all seven translate") { Providers::TRANSLATORS.keys.length == 7 }
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

  # --- 13. ProviderObject, 14. ProvidersListModel -------------------------

  d.step("the provider dropdown models list the right providers") do
    ProvidersListModel.new("translators").then do |model|
      d.check("the translators list holds seven") { model.n_items == 7 }
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
      ProvidersListModel.new("everything").n_items == 7
    end
  end

  # --- 15. Settings -------------------------------------------------------

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

  # --- 16. ProviderSettings -----------------------------------------------

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

  # --- 17. Provider base --------------------------------------------------

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

  # --- 18-24. the seven provider classes ----------------------------------

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

  # --- 25. Session --------------------------------------------------------

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
        raised_by { session.send_and_read("GET", "http://127.0.0.1:1/x") }.is_a?(ResponseError)
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

  # --- 26. SessionHelpers -------------------------------------------------

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
        raised_by { probe.get("http://127.0.0.1:1/x") }.is_a?(RequestError)
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

  # --- 27. BackgroundTask -------------------------------------------------

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
  # Asserted explicitly so this script cannot be mistaken for covering the
  # upstream UI. Every row of .reports/component-inventory.md is still absent,
  # and these checks fail the moment one of them lands without being driven.

  d.step("the scaffold has none of upstream's actions, menus or dialogs") do
    %w[pronunciation preferences about quit].each do |name|
      d.check("app.#{name} is not registered yet") { !app.app.has_action?(name) }
      d.check("and has no accelerator bound") { app.app.get_accels_for_action("app.#{name}").empty? }
    end
    %w[
      back forward switch from to clear font-size-inc font-size-dec paste copy
      listen-dest listen-src suggest suggest-ok suggest-cancel translation
    ].each do |name|
      d.check("win.#{name} is not registered yet") { !app.window.has_action?(name) }
    end
    d.check("no dialog is open") { app.window.visible_dialog.nil? }
    d.check("the header bar has no menu button yet") do
      [].then do |buttons|
        walk = lambda do |widget|
          if widget.is_a?(Gtk::MenuButton)
            buttons << widget
          end
          child = widget.first_child
          while child
            walk.call(child)
            child = child.next_sibling
          end
        end
        walk.call(app.header_bar)
        buttons.empty?
      end
    end
    d.check("the translator window class is not defined yet") { !Dialect.const_defined?(:Window) }
    d.check("the status page is still the only content state") do
      app.toolbar_view.content.equal?(app.status_page)
    end
    d.shot("03-scaffold")
  end

  # --- 28. the window's close-request handler -----------------------------
  #
  # Last, because emitting close-request runs GTK's own default handler too,
  # which takes the window down.

  d.step("closing the window writes the size back to settings") do
    d.shot("04-before-close")
    Settings.get.window_size = [100, 100]
    # Inside the 640x480 virtual display, again so GTK does not clamp it.
    app.window.set_default_size(620, 455)
    pump(300)
    app.window.signal_emit("close-request").then do |stopped|
      d.check("the handler does not veto the close") { stopped == false }
    end
    d.check("the size was persisted") { Settings.get.window_size == [620, 455] }
    d.check("and reached the file on disk") do
      JSON.parse(File.read(Settings.get.path))["window-size"] == [620, 455]
    end
  end
end

PROBE.stop
