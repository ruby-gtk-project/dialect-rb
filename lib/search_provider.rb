# frozen_string_literal: true

require 'gio2'

require_relative 'background_task'
require_relative 'define'
require_relative 'languages'
require_relative 'provider'
require_relative 'provider_errors'
require_relative 'providers'
require_relative 'settings'

# The GNOME Shell search provider: translating text typed into the Shell's
# overview search without the window ever opening.
#
# Ported from upstream's dialect/search_provider/search_provider.in, with its
# registration files dialect/search_provider/app.drey.Dialect.SearchProvider.ini
# and dialect/search_provider/app.drey.Dialect.SearchProvider.service.in
# (mirrored as data/dbus-1/services/app.drey.Dialect.SearchProvider.service
# and data/gnome-shell/search-providers/app.drey.Dialect.SearchProvider.ini).
#
# Implements org.gnome.Shell.SearchProvider2:
#
#   GetInitialResultSet(as)       -> as      ids for the typed terms
#   GetSubsearchResultSet(as, as) -> as      the same, for the narrowed query
#   GetResultMetas(as)            -> aa{sv}  id/name/description per result
#   ActivateResult(s, as, u)                copies, or opens the app
#   LaunchSearch(as, u)                     opens the app with the query
#
# Upstream's wrap_results reads the reply signature off each method's
# Gio.DBusMethodInfo.out_args at call time; the Ruby bindings return unusable
# boxed structs for both Gio::DBusNodeInfo#interfaces and
# Gio::DBusMethodInfo#out_args (both come back as an array holding one
# "\u0001" string rather than the structs themselves), so each reply is built
# by hand in #handle_method_call instead, the same way lib/shell_search_provider.rb
# does in the gnome-contacts-rb pilot this port follows.
#
# Upstream keeps the loaded translator around and watches both the active
# translator and that provider's own `src-langs`/`dest-langs` settings so its
# cached src/dest language stay current. This port caches only the
# initialized translator itself (the expensive part — a provider's
# #init_trans call); the current source and destination languages are read
# off it fresh on every search, so there is nothing to watch for.
#
# Upstream's translate call is awaited from inside a GLib coroutine; the
# port's provider methods are plain blocking calls, and this process has no
# running main loop to deliver an async result onto, so BackgroundTask#wait
# is used instead — it was built for exactly this caller, see its class
# comment in background_task.rb.
class SearchProvider
  INTERFACE = 'org.gnome.Shell.SearchProvider2'
  BUS_NAME = "#{Define::APP_ID}.SearchProvider"
  OBJECT_PATH = '/app/drey/Dialect/SearchProvider'
  DEFAULT_BINARY = 'dialect'
  INACTIVITY_TIMEOUT = 10_000

  CLIPBOARD_PREFIX = 'copy-to-clipboard'
  ERROR_PREFIX = 'translation-error'

  NODE_XML = <<~XML
    <node>
      <interface name="org.gnome.Shell.SearchProvider2">
        <method name="GetInitialResultSet">
          <arg type="as" name="terms" direction="in"/>
          <arg type="as" name="results" direction="out"/>
        </method>
        <method name="GetSubsearchResultSet">
          <arg type="as" name="previous_results" direction="in"/>
          <arg type="as" name="terms" direction="in"/>
          <arg type="as" name="results" direction="out"/>
        </method>
        <method name="GetResultMetas">
          <arg type="as" name="identifiers" direction="in"/>
          <arg type="aa{sv}" name="metas" direction="out"/>
        </method>
        <method name="ActivateResult">
          <arg type="s" name="identifier" direction="in"/>
          <arg type="as" name="terms" direction="in"/>
          <arg type="u" name="timestamp" direction="in"/>
        </method>
        <method name="LaunchSearch">
          <arg type="as" name="terms" direction="in"/>
          <arg type="u" name="timestamp" direction="in"/>
        </method>
      </interface>
    </node>
  XML

  # Runs the provider as the standalone D-Bus-activated service the
  # .service file points at: a Gio::Application owning the bus name,
  # registering the object on the connection it gets at startup, and exiting
  # once the shell has gone quiet for INACTIVITY_TIMEOUT, matching upstream's
  # own GApplication(flags=IS_SERVICE, inactivity_timeout=10000).
  def self.run(binary: DEFAULT_BINARY)
    new(binary: binary).then do |provider|
      Gio::Application.new(BUS_NAME, :is_service).tap do |app|
        app.inactivity_timeout = INACTIVITY_TIMEOUT
        app.signal_connect('startup') { provider.register(app.dbus_connection) }
        app.signal_connect('activate') { nil }
        app.run([])
      end
    end
  end

  def initialize(binary: DEFAULT_BINARY, settings: nil)
    @binary = binary
    @settings = settings || Settings.get
    @translator = nil
    @last_dest_language = nil
    @translations = {}

    # Upstream's `_on_translator_changed`: the next search re-initializes the
    # translator once the active one has changed under it.
    @settings.on_provider_changed { |kind, _name| @translator = nil if kind == 'translator' }
  end

  # Registers the provider on the connection the application already owns,
  # the way upstream does from Application.do_dbus_register.
  def register(connection)
    interface_info.then do |interface|
      connection.register_object(OBJECT_PATH, interface, method(:handle_method_call))
    end
  rescue StandardError, GLib::Error => e
    warn "Could not register the search provider: #{e.message}"
    nil
  end

  # Note #lookup_interface rather than #interfaces — see the class comment.
  def interface_info = Gio::DBusNodeInfo.new(NODE_XML).lookup_interface(INTERFACE)

  # --- Interface methods ---------------------------------------------------

  # Upstream's GetInitialResultSet. Live search translation needs both the
  # global live-translation setting and the "Show Translations in Desktop
  # Search" switch on; otherwise the shell is handed a single prompt result
  # inviting the user to open the app instead of a translation.
  def initial_result_set(terms)
    text = Array(terms).map(&:to_s).join(' ')

    if live_enabled?
      live_result_set(text)
    elsif text.empty?
      []
    else
      [prompt_for(text)]
    end
  end

  # Narrowing a search re-runs it: upstream's GetSubsearchResultSet does the
  # same, ignoring the previous results entirely.
  def subsearch_result_set(_previous_results, terms) = initial_result_set(terms)

  def result_metas(identifiers)
    identifiers.map(&:to_s).then do |ids|
      if copy_pair?(ids)
        copy_metas(ids[0], ids[1])
      else
        ids.map { |id| single_meta(id) }
      end
    end
  end

  # Clicking the clipboard row only copies, which the shell itself does from
  # `clipboardText`; clicking the translation (or the prompt result) opens
  # the app, matching upstream's ActivateResult.
  def activate_result(identifier, terms, timestamp)
    unless identifier.to_s.start_with?(CLIPBOARD_PREFIX)
      launch_search(terms, timestamp)
    end
  end

  # Opens the app with the typed query pre-filled, as upstream's
  # LaunchSearch spawns `@BIN@ --text <text>`.
  def launch_search(terms, _timestamp)
    Array(terms).map(&:to_s).join(' ').then do |text|
      Process.detach(Process.spawn(@binary, '--text', text))
    end
  end

  private

    # The gio2 bindings hand the method call's arguments to this closure
    # already unpacked into a plain Ruby array (one native value per `in`
    # arg), not as a Gio::Variant tuple to pick apart — unlike
    # Gio::DBusNodeInfo#interfaces and Gio::DBusMethodInfo#out_args (see the
    # class comment), this one marshals cleanly, so +parameters+ is indexed
    # directly rather than walked with #get_child_value.
    def handle_method_call(_connection, _sender, _path, _interface, method_name, parameters, invocation)
      case method_name
      when 'GetInitialResultSet'
        invocation.return_value(string_array(initial_result_set(parameters[0])))
      when 'GetSubsearchResultSet'
        invocation.return_value(string_array(subsearch_result_set(parameters[0], parameters[1])))
      when 'GetResultMetas'
        invocation.return_value(metas_variant(result_metas(parameters[0])))
      when 'ActivateResult'
        activate_result(parameters[0], parameters[1], parameters[2])
        invocation.return_value(nil)
      when 'LaunchSearch'
        launch_search(parameters[0], parameters[1])
        invocation.return_value(nil)
      else
        invocation.return_dbus_error("#{INTERFACE}.UnknownMethod", "Unknown method #{method_name}")
      end
    rescue StandardError => e
      invocation.return_dbus_error("#{INTERFACE}.Error", e.message)
    end

    def live_enabled? = @settings.live_translation && @settings.sp_translation

    def prompt_for(text)
      provider = Providers::TRANSLATORS.fetch(@settings.active_translator)
      "Translate “#{text}” with #{provider.prettyname}"
    end

    # Upstream's GetInitialResultSet body once live translation is on: load
    # the translator if needed, and, as long as the two languages actually
    # differ and there is text to translate, translate it.
    def live_result_set(text)
      error_id = ERROR_PREFIX + text

      begin
        ensure_loaded!
      rescue StandardError
        @translations[error_id] = 'Failed loading the translation service'
      end

      if @translator.nil?
        [error_id]
      else
        dest_language = current_dest_language

        if dest_language && current_src_language != dest_language && !text.empty?
          translate(text, dest_language, error_id)
        else
          []
        end
      end
    end

    def ensure_loaded!
      @translator ||= Providers::TRANSLATORS.fetch(@settings.active_translator).new.tap(&:init_trans)
    end

    def current_src_language
      @translator.supports_detection? ? 'auto' : @translator.recent_src_langs.first
    end

    def current_dest_language = @translator.recent_dest_langs.first

    def translate(text, dest_language, error_id)
      src, dest = @translator.denormalize_lang(current_src_language, dest_language)
      request = TranslationRequest.new(text, src, dest)
      result = [error_id]

      BackgroundTask.run(
        on_success: lambda { |translation|
          @translations[text] = translation.text
          @last_dest_language = dest_language
          result = [text, CLIPBOARD_PREFIX + text]
        },
        on_error: lambda { |error|
          @translations[error_id] = message_for(error)
          result = [error_id]
        },
      ) { @translator.translate(request) }.wait

      result
    end

    def message_for(error)
      case error
      when RequestError then 'Translation failed, check for network issues'
      when APIKeyInvalid then 'The provided API key is invalid'
      when APIKeyRequired then 'API key is required to use the service'
      else 'Translation failed'
      end
    end

    def copy_pair?(ids) = ids.length == 2 && @translations.key?(ids[0]) && ids[1] == CLIPBOARD_PREFIX + ids[0]

    def copy_metas(identifier, clipboard_identifier)
      @translations.fetch(identifier).then do |text|
        [
          { 'id' => identifier, 'name' => text, 'description' => description_for },
          {
            'id'            => clipboard_identifier,
            'name'          => 'Copy',
            'description'   => 'Copy translation to clipboard',
            'clipboardText' => text,
          },
        ]
      end.tap { @translations.clear }
    end

    def description_for
      if @last_dest_language.nil? || @translator.nil?
        ''
      else
        lang_name = Languages.lang_name(@last_dest_language) || @last_dest_language
        "#{lang_name} — #{@translator.prettyname}"
      end
    end

    def single_meta(identifier) = { 'id' => identifier, 'name' => @translations.fetch(identifier, identifier) }

    # Reply variants are built by parsing GVariant text: GLib::Variant.new
    # cannot construct a dictionary in these bindings (it raises
    # NotImplementedError for a{sv}) and cannot build the tuple a D-Bus reply
    # needs either, but GLib::Variant.parse(text, type) handles both — see
    # the gnome-contacts-rb pilot's shell_search_provider.rb for the same fix.
    def string_array(values)
      GLib::Variant.parse("([#{values.map { |v| quote(v) }.join(', ')}],)", '(as)')
    end

    def metas_variant(metas)
      GLib::Variant.parse("(#{metas_text(metas)},)", '(aa{sv})')
    end

    def metas_text(metas)
      "[#{metas.map { |meta| meta_text(meta) }.join(', ')}]"
    end

    def meta_text(meta)
      "{#{meta.map { |key, value| "#{quote(key)}: <#{quote(value)}>" }.join(', ')}}"
    end

    ESCAPES = { '\\' => '\\\\', '"' => '\\"' }.freeze

    def quote(value) = %("#{value.to_s.gsub(/[\\"]/) { |char| ESCAPES.fetch(char) }}")
end
