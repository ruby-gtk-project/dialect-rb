# frozen_string_literal: true

require 'gtk4'
require 'adwaita'

require_relative 'languages'
require_relative 'lang_row'

# The language button in the header bar, and the searchable popover it opens:
# a recently-used list on top, a separator, then every language the provider
# offers, sorted by name and filtered by the search entry.
#
# Ported from upstream's dialect/widgets/lang_selector.blp and
# dialect/widgets/lang_selector.py.
#
# Upstream declares `selected` as a GObject property and `user-selection-changed`
# as a GObject signal, and the window connects to notify::selected and to the
# signal from the template. A GLib::Object subclass in the Ruby bindings
# cannot declare either without a full type registration, which would take the
# constructor's arguments away, so both are delivered to blocks handed in at
# construction. `selected=` only calls back when the value actually changes,
# which is the one property of GObject's notify the window's handlers rely on:
# the src and dest handlers each correct the other selector, and a callback on
# every write would bounce between them forever.
class LangSelector < Adwaita::Bin
  AUTO_CODE = 'auto'
  AUTO_NAME = 'Auto'

  attr_reader :selected

  def initialize(tooltip: nil, on_selected_changed: nil, on_user_selection_changed: nil)
    super()

    @tooltip = tooltip
    @on_selected_changed = on_selected_changed
    @on_user_selection_changed = on_user_selection_changed
    @selected = ''
    @model = nil
    @recent_model = nil
  end

  def build
    tap do |selector|
      selector.child = button
      selector.tooltip_text = @tooltip

      button.tap do |menu_button|
        menu_button.child = button_box
        menu_button.popover = popover

        button_box.tap do |box|
          box.append(label)
          box.append(insight)
        end
      end

      popover.tap do |pop|
        pop.child = popover_box

        pop.signal_connect('show') { search.grab_focus }
        pop.signal_connect('closed') { on_popover_closed }

        popover_box.tap do |box|
          box.append(search_box)
          box.append(scroll)

          search_box.tap do |container|
            container.append(search)

            search.tap do |entry|
              entry.key_capture_widget = pop
              entry.add_controller(search_key_controller)
              entry.signal_connect('changed') { on_search }
              entry.signal_connect('activate') { on_search_activate }

              search_key_controller.signal_connect('key-pressed') do |_controller, keyval, _keycode, _state|
                on_search_key_pressed(keyval)
              end
            end
          end

          scroll.tap do |scrolled|
            scrolled.child = lists_box

            lists_box.tap do |box|
              box.append(revealer)
              box.append(lang_list)

              revealer.tap do |rev|
                rev.child = recent_box

                recent_box.tap do |container|
                  container.append(recent_list)
                  container.append(separator)
                end
              end
            end
          end
        end
      end

      [recent_list, lang_list].each do |list|
        list.signal_connect('row-activated') { |_list, row| on_row_activated(row) }
      end
    end
  end

  # Binds the full and recent language models, as upstream's bind_models does:
  # the full list is sorted by name and filtered by the search entry, the
  # recent list is shown as the model orders it.
  def bind_models(langs, recent)
    @model = langs
    @recent_model = recent

    recent.model.signal_connect('items-changed') { recent.set_selected(selected) }

    lang_list.bind_model(filter_model) { |lang| LangRow.new(lang).build }
    recent_list.bind_model(recent.model) { |lang| LangRow.new(lang).build }
  end

  # Sets the selected code, telling the models and the label about it. The
  # callback only fires on a real change, mirroring GObject's notify.
  def selected=(code)
    code.to_s.then do |value|
      unless value == @selected
        @selected = value
        apply_selection
        @on_selected_changed&.call(value)
      end
    end

    code
  end

  # Shows the detected language in brackets beside "Auto", upstream's
  # set_insight.
  def set_insight(code)
    if @selected == AUTO_CODE
      insight.label = "(#{lang_name(code)})"
    end
  end

  # Opens the popover, for the window's `from` and `to` actions.
  def popup = button.popup

  # Memoized widget methods

  def button
    @button ||= Gtk::MenuButton.new.tap do |menu_button|
      menu_button.always_show_arrow = true
      menu_button.add_css_class('raised')
    end
  end

  def button_box = @button_box ||= Gtk::Box.new(:horizontal, 3)

  def label
    @label ||= Gtk::Label.new.tap do |text|
      text.ellipsize = :end
      text.xalign = 0
    end
  end

  def insight
    @insight ||= Gtk::Label.new.tap do |text|
      text.ellipsize = :end
      text.xalign = 0
    end
  end

  def popover
    @popover ||= Gtk::Popover.new.tap do |pop|
      pop.height_request = 300
      pop.add_css_class('lang-selector')
      pop.add_css_class('menu')
    end
  end

  def popover_box = @popover_box ||= Gtk::Box.new(:vertical, 0)

  def search_box
    @search_box ||= Gtk::Box.new(:vertical, 0).tap do |box|
      box.add_css_class('search_box')
    end
  end

  def search
    @search ||= Gtk::SearchEntry.new.tap do |entry|
      entry.placeholder_text = 'Search Languages…'
    end
  end

  def search_key_controller = @search_key_controller ||= Gtk::EventControllerKey.new

  def scroll
    @scroll ||= Gtk::ScrolledWindow.new.tap do |scrolled|
      scrolled.vexpand = true
    end
  end

  def lists_box = @lists_box ||= Gtk::Box.new(:vertical, 0)

  def revealer
    @revealer ||= Gtk::Revealer.new.tap do |rev|
      rev.reveal_child = true
    end
  end

  def recent_box = @recent_box ||= Gtk::Box.new(:vertical, 0)

  def recent_list
    @recent_list ||= Gtk::ListBox.new.tap do |list|
      list.selection_mode = :single
    end
  end

  def separator = @separator ||= Gtk::Separator.new(:horizontal)

  def lang_list
    @lang_list ||= Gtk::ListBox.new.tap do |list|
      list.selection_mode = :single
    end
  end

  # The search filter and the by-name sort upstream wraps the full model in.
  #
  # Upstream writes both as closures: a Gtk.CustomFilter running a
  # case-insensitive re.search over the name, and a Gtk.CustomSorter comparing
  # the lowercased names. Gtk::CustomSorter is unusable in the Ruby bindings —
  # its block is handed the two items as raw pointers, arriving as Integers,
  # so there is nothing to compare — and the equivalent built-ins say the same
  # thing without a closure: a StringFilter in substring mode ignoring case is
  # what re.search over a plain needle does, and a StringSorter ignoring case
  # is the lowercased comparison. Both read the `name` property off LangObject.
  def name_expression = Gtk::PropertyExpression.new(LangObject, nil, 'name')

  # Both take the expression through the setter rather than the constructor:
  # the constructor's argument is transfer-full, and the Ruby bindings hand
  # it an unboxed GtkExpression, which fails g_object_ref and prints a
  # GLib-GObject-CRITICAL on every build.
  def filter
    @filter ||= Gtk::StringFilter.new(nil).tap do |string_filter|
      string_filter.expression = name_expression
      string_filter.match_mode = :substring
      string_filter.ignore_case = true
    end
  end

  def sorter
    @sorter ||= Gtk::StringSorter.new(nil).tap do |string_sorter|
      string_sorter.expression = name_expression
      string_sorter.ignore_case = true
    end
  end

  def sorted_model = @sorted_model ||= Gtk::SortListModel.new(@model.model, sorter)
  def filter_model = @filter_model ||= Gtk::FilterListModel.new(sorted_model, filter)

  private

    def lang_name(code)
      @model.then do |model|
        if model
          model.names_func.call(code) || code
        else
          code
        end
      end
    end

    # Upstream's _on_selected_changed: mark the models, relabel the button and
    # drop any detected-language insight.
    def apply_selection
      @model&.set_selected(@selected)
      @recent_model&.set_selected(@selected)

      if @selected == AUTO_CODE
        label.label = AUTO_NAME
      else
        label.label = lang_name(@selected)
      end

      insight.label = ''
    end

    def on_row_activated(row)
      popover.popdown
      self.selected = row.lang.code
      @on_user_selection_changed&.call(row.lang.code)
    end

    def on_popover_closed
      scroll.vadjustment.value = 0
      search.text = ''
    end

    # The recent list is hidden while a search is running, as upstream does,
    # and the needle goes to the filter, which re-runs itself.
    def on_search
      revealer.reveal_child = search.text.empty?
      filter.search = search.text
    end

    # Enter in the search entry activates the first match.
    def on_search_activate
      unless search.text.empty?
        lang_list.get_row_at_index(0).then do |row|
          if row
            lang_list.signal_emit('row-activated', row)
          end
        end
      end

      false
    end

    # Escape closes the popover; Down is swallowed so the search entry keeps
    # the focus, both as upstream does.
    def on_search_key_pressed(keyval)
      case keyval
      when Gdk::Keyval::KEY_Escape
        popover.popdown
        false
      when Gdk::Keyval::KEY_Down then true
      else false
      end
    end

end
