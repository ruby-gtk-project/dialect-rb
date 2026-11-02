# frozen_string_literal: true

require 'optparse'

require 'gtk4'
require 'adwaita'

require_relative 'define'
require_relative 'icons'
require_relative 'preferences_dialog'
require_relative 'providers'
require_relative 'settings'
require_relative 'style'
require_relative 'window'

module Dialect
  # The application: its actions, its accelerators, its About dialog and the
  # command line it answers.
  #
  # Ported from upstream's dialect/main.py, with the About dialog's text from
  # data/app.drey.Dialect.metainfo.xml.in.in — upstream builds that dialog
  # with Adw.AboutDialog.new_from_appdata, reading the metainfo out of the
  # app's GResource. The port builds no GResource, so the same fields are set
  # directly.
  #
  # Upstream subclasses Adw.Application. That class is broken in the Ruby
  # bindings, so the application object is a Gtk::Application and
  # libadwaita is initialized by hand: without adw_init() the Adwaita
  # stylesheet is never installed and every Adwaita widget renders as an
  # unstyled GTK box.
  #
  # Upstream declares its command line options through
  # Gio.Application.add_main_option under HANDLES_COMMAND_LINE. The port
  # parses the same four options with OptionParser before the loop starts and
  # hands them to the window once the translator has finished loading, which
  # is the same sequencing upstream gets from its notify::translator-loading
  # handler.
  class Application
    APP_ID = Define::APP_ID

    COMMENTS = 'A translation app for GNOME.'
    COPYRIGHT = 'Copyright 2020–2024 The Dialect Authors'
    DEVELOPER_NAME = 'The Dialect Authors'
    DEVELOPERS = [
      'Mufeed Ali',
      'Rafael Mardojai CM http://rafaelmardojai.com',
      'Libretto',
    ].freeze
    WEBSITE = 'https://dialectapp.org/'
    ISSUE_URL = 'https://github.com/dialect-app/dialect/issues/'
    DONATE_URL = 'https://opencollective.com/dialect'

    # Upstream's set_accels_for_action calls, as detailed action name =>
    # accelerators. The `listen-src` and `listen-dest` pair upstream also
    # binds is left out with the rest of text-to-speech; see window.rb.
    ACCELS = {
      'app.pronunciation'     => ['<Primary>P'],
      'app.preferences'       => ['<Primary>comma'],
      'app.quit'              => ['<Primary>Q'],
      'win.back'              => ['<Alt>Left'],
      'win.forward'           => ['<Alt>Right'],
      'win.switch'            => ['<Primary>S'],
      'win.from'              => ['<Primary>F'],
      'win.to'                => ['<Primary>T'],
      'win.clear'             => ['<Primary>D'],
      'win.font-size-inc'     => ['<Primary>plus', '<Primary>KP_Add'],
      'win.font-size-dec'     => ['<Primary>minus', '<Primary>KP_Subtract'],
      'win.paste'             => ['<Primary><Shift>V'],
      'win.copy'              => ['<Primary><Shift>C'],
      'win.show-help-overlay' => ['<Primary>question'],
    }.freeze

    attr_reader :argv

    def initialize(argv: [])
      @argv = parse_options(argv)
      @window = nil
    end

    def build
      app.tap do
        app.signal_connect('activate') do
          Adwaita.init
          Style.load
          Icons.load

          setup_actions
          setup_accels

          window.tap do |win|
            win.build
            win.present

            if win.translator_loading?
              win.on_translator_loading do |loading|
                unless loading
                  process_command_line
                end
              end
            else
              process_command_line
            end
          end
        end
      end
    end

    def run = app.run([])

    # Adwaita::Application is broken in the Ruby bindings; the application
    # object comes from Gtk and only the window is Adwaita.
    def app = @app ||= Gtk::Application.new(APP_ID, :default_flags)

    def settings = @settings ||= Settings.get

    def window = @window ||= Window.new(app, settings: settings)

    # Memoized dialog methods

    def about_dialog
      @about_dialog ||= Adwaita::AboutDialog.new.tap do |dialog|
        dialog.application_name = 'Dialect'
        dialog.application_icon = APP_ID
        dialog.version = Define::VERSION
        dialog.comments = COMMENTS
        dialog.copyright = COPYRIGHT
        dialog.developer_name = DEVELOPER_NAME
        dialog.developers = DEVELOPERS
        dialog.license_type = Gtk::License::GPL_3_0
        dialog.website = WEBSITE
        dialog.issue_url = ISSUE_URL
        dialog.add_link('Donate', DONATE_URL)
      end
    end

    private

      # Upstream's four command line options, by their long and short names.
      def parse_options(arguments)
        {}.tap do |options|
          OptionParser.new do |parser|
            parser.banner = 'Usage: dialect [options]'
            parser.on('-n', '--selection', 'Translate text from the primary clipboard') do
              options[:selection] = true
            end
            parser.on('-t', '--text TEXT', 'Text to translate') { |text| options[:text] = text }
            parser.on('-s', '--src CODE', 'Source lang code') { |code| options[:src] = code }
            parser.on('-d', '--dest CODE', 'Destination lang code') { |code| options[:dest] = code }
          end.parse(arguments.dup)
        end
      rescue OptionParser::ParseError
        {}
      end

      def process_command_line
        unless @argv.empty?
          @argv.then do |options|
            @argv = {}

            if options[:text].to_s.empty? && options[:selection]
              window.queue_selection_translation(options[:src], options[:dest])
            elsif !options[:text].to_s.empty?
              window.translate(options[:text], options[:src], options[:dest])
            end
          end
        end
      end

      def setup_actions
        Gio::SimpleAction.new('pronunciation', nil, GLib::Variant.new(settings.show_pronunciation)).tap do |action|
          action.signal_connect('change-state') { |_action, value| on_pronunciation(action, value) }
          app.add_action(action)
        end

        {
          'preferences' => -> { on_preferences },
          'about'       => -> { about_dialog.present(window.window) },
          'quit'        => -> { app.quit },
        }.each do |name, handler|
          Gio::SimpleAction.new(name, nil).tap do |action|
            action.signal_connect('activate') { handler.call }
            app.add_action(action)
          end
        end
      end

      def setup_accels
        ACCELS.each do |action, accels|
          app.set_accels_for_action(action, accels)
        end
      end

      def on_pronunciation(action, value)
        action.state = value
        settings.show_pronunciation = value.get_boolean
        window.check_pronunciation
      end

      def on_preferences
        PreferencesDialog.new(window, settings: settings).build.present(window.window)
      end
  end
end
