# frozen_string_literal: true

# The exceptions providers raise, which the window turns into its error and
# API-key pages.
#
# Ported from upstream's dialect/providers/errors.py.

# Raised when an HTTP request itself fails, before any provider payload could
# be read. Deliberately not a ProviderError: upstream distinguishes "the
# network broke" from "the service said no".
class RequestError < StandardError; end

# Raised when a provider fails.
class ProviderError < StandardError; end

# Raised when a provider failed in a way the port does not model explicitly.
class UnexpectedError < ProviderError; end

# Raised when the provider cannot work until the user supplies an API key.
class APIKeyRequired < ProviderError; end

# Raised when the provider rejected the API key it was given.
class APIKeyInvalid < ProviderError; end

# Raised when a lang code is not one the provider accepts.
class InvalidLangCode < ProviderError; end

# Raised when the request carried more segments than the provider accepts.
class BatchSizeExceeded < ProviderError; end

# Raised when the text is longer than the provider's character limit.
class CharactersLimitExceeded < ProviderError; end

# Raised when the account's service quota is spent.
class ServiceLimitReached < ProviderError; end
