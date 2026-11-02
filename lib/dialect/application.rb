# frozen_string_literal: true

require "gtk4"
require "adwaita"

require_relative "../settings"
require_relative "../style"
require_relative "../providers"

module Dialect
  # The port's application: one window, and a status page naming how far the
  # port has got. Everything else grows from here — replace the status page
  # with the real content, keep the shape.
  #
  # House style (see .claude/skills/ruby-gtk): every widget is a memoized
  # method, all configuration lives in its `tap`, assembly happens only in
  # `build`, and the launcher is one expression.
  class Application
    def build
      app.tap do
        app.signal_connect("activate") do
          # Upstream gets this from Adw.Application. The port cannot use
          # Adwaita::Application — it is broken in the Ruby bindings — so
          # libadwaita has to be initialized by hand, as the pilot port does.
          # Without it adw_init() never runs, the Adwaita stylesheet is never
          # installed and every Adwaita widget renders as an unstyled GTK box:
          # the status page's icon comes out 16px and its title in body text.
          Adwaita.init

          Style.load

          window.tap do |win|
            win.content = toolbar_view

            win.signal_connect("close-request") do
              settings.window_size = [win.default_width, win.default_height]
              false
            end
          end

          toolbar_view.tap do |view|
            view.add_top_bar(header_bar)
            view.content = status_page
          end

          window.present
        end
      end
    end

    # Adwaita::Application is broken in the Ruby bindings; the application
    # object comes from Gtk and only the window is Adwaita.
    def app = @app ||= Gtk::Application.new("org.rubygtkproject.Dialect", :default_flags)

    def settings = @settings ||= Settings.get

    # The window size comes back from settings, the way upstream's
    # `window-size` key restores it.
    def window
      @window ||= Adwaita::ApplicationWindow.new(app).tap do |win|
        win.title = "dialect"
        win.set_default_size(*settings.window_size)
      end
    end

    def toolbar_view = @toolbar_view ||= Adwaita::ToolbarView.new
    def header_bar = @header_bar ||= Adwaita::HeaderBar.new

    def status_page
      @status_page ||= Adwaita::StatusPage.new.tap do |page|
        page.title = "dialect"
        page.description = "#{Providers::TRANSLATORS.length} translation providers are ported. " \
                           "The translation window is not."
        page.icon_name = "applications-engineering-symbolic"
      end
    end
  end
end
