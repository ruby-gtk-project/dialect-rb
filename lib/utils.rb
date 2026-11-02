# frozen_string_literal: true

# Enumerable#to_set lives in set.rb, which Ruby only autoloads from 3.4 on;
# the gemspec supports 3.2.
require 'set'

# Small list helpers shared across the app.
#
# Ported from upstream's dialect/utils.py.
module Utils
  module_function

  # Gets the first item of +list1+ that also appears in +list2+, or nil when
  # the two share nothing.
  def find_item_match(list1, list2)
    list2.to_a.to_set.then do |set_to_check|
      list1.to_a.find { |item| set_to_check.include?(item) }
    end
  end

  # Gets the first item of +list+ that is not +exclude+, or nil when every
  # item is excluded.
  def first_exclude(list, exclude)
    list.to_a.find { |item| item != exclude }
  end
end
