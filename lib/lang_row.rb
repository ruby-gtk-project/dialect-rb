# frozen_string_literal: true

require 'gtk4'

require_relative 'languages'

# One language in a selector popover's list: its name, and a check mark when
# it is the selected one.
#
# Ported from upstream's dialect/widgets/lang_row.blp and the LangRow class at
# the bottom of dialect/widgets/lang_selector.py.
#
# The check mark's visibility is bound to the LangObject's `selected`
# property, exactly as upstream does, so a row redraws itself when the model
# marks a different language — the row never has to be rebuilt.
class LangRow < Gtk::ListBoxRow
  attr_reader :lang

  def initialize(lang)
    super()

    @lang = lang
    self.tooltip_text = lang.name
  end

  def build
    tap do |row|
      row.child = box

      box.tap do |container|
        container.append(name_label)
        container.append(selection_image)
      end

      # The binding is kept in an ivar, not dropped on the floor: the Ruby
      # wrapper for a GLib::Binding owns a reference, and letting it be
      # garbage collected unbinds the property — the check mark then stops
      # following the model and the row silently goes stale.
      @selection_binding = lang.bind_property(
        'selected',
        selection_image,
        'visible',
        :sync_create,
      )
    end
  end

  # Memoized widget methods

  def box = @box ||= Gtk::Box.new(:horizontal, 6)

  def name_label
    @name_label ||= Gtk::Label.new(lang.name).tap do |label|
      label.xalign = 0
      label.ellipsize = :end
    end
  end

  def selection_image
    @selection_image ||= Gtk::Image.new(icon_name: 'object-select-symbolic').tap do |image|
      image.visible = false
    end
  end
end
