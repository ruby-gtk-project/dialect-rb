# frozen_string_literal: true

require 'gtk4'
require 'adwaita'

# The speak button both sides of the translation box show: an icon that
# switches between ready, in-progress, error and loading states, with a
# progress bar overlaid while audio is being fetched.
#
# Ported from upstream's dialect/widgets/speech_button.py and
# dialect/widgets/speech_button.blp.
class SpeechButton < Gtk::Button
  READY_PAGE = 'ready'
  PROGRESS_PAGE = 'progress'
  ERROR_PAGE = 'error'
  LOADING_PAGE = 'loading'

  def initialize
    super()

    self.tooltip_text = 'Listen'
    add_css_class('speech-button')
  end

  def build
    tap do |button|
      button.child = overlay

      overlay.tap do |ov|
        ov.add_overlay(progress_bar)
        ov.child = stack
      end

      stack.tap do |s|
        s.add_named(ready_icon, READY_PAGE)
        s.add_named(progress_icon, PROGRESS_PAGE)
        s.add_named(error_icon, ERROR_PAGE)
        s.add_named(loading_spinner, LOADING_PAGE)
        s.visible_child_name = READY_PAGE
      end
    end
  end

  # Upstream's SpeechButton.ready.
  def ready
    stack.visible_child_name = READY_PAGE
    self.tooltip_text = 'Listen'
    progress_bar.visible = false
  end

  # Upstream's SpeechButton.progress.
  def progress(fraction)
    unless stack.visible_child_name == PROGRESS_PAGE
      stack.visible_child_name = PROGRESS_PAGE
      self.tooltip_text = 'Cancel Audio'
      progress_bar.visible = true
    end

    progress_bar.fraction = fraction
  end

  # Upstream's SpeechButton.error.
  def error(message)
    stack.visible_child_name = ERROR_PAGE
    self.tooltip_text = message
    progress_bar.visible = false
  end

  # Upstream's SpeechButton.loading.
  def loading
    stack.visible_child_name = LOADING_PAGE
    self.tooltip_text = 'Loading…'
    progress_bar.visible = false
  end

  # Memoized widget methods

  def overlay = @overlay ||= Gtk::Overlay.new
  def stack = @stack ||= Gtk::Stack.new

  def progress_bar
    @progress_bar ||= Gtk::ProgressBar.new.tap do |bar|
      bar.visible = false
      bar.valign = :end
      bar.add_css_class('osd')
    end
  end

  def ready_icon = @ready_icon ||= Gtk::Image.new(icon_name: 'audio-speakers-symbolic')
  def progress_icon = @progress_icon ||= Gtk::Image.new(icon_name: 'media-playback-stop-symbolic')
  def error_icon = @error_icon ||= Gtk::Image.new(icon_name: 'dialect-speakers-broken-symbolic')
  def loading_spinner = @loading_spinner ||= Adwaita::Spinner.new
end
