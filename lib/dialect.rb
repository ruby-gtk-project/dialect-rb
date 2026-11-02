# frozen_string_literal: true

# The ported library. Each file here maps to one upstream source file; see the
# class comment in each for the file it came from.
require_relative "define"
require_relative "utils"
require_relative "provider_errors"
require_relative "languages"
require_relative "session"
require_relative "background_task"
require_relative "provider"
require_relative "provider_settings"
require_relative "providers"
require_relative "settings"
require_relative "style"
require_relative "icons"

# Widgets, innermost first: each is built from the ones above it.
require_relative "text_view"
require_relative "theme_switcher"
require_relative "lang_row"
require_relative "lang_selector"
require_relative "main_menu"
require_relative "shortcuts_window"
require_relative "provider_preferences"
require_relative "preferences_dialog"
require_relative "window"

require_relative "main"
