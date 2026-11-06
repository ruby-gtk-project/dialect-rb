# frozen_string_literal: true

require 'json'
require 'soup3'
require 'uri'

require_relative 'provider_errors'

# Raised when a response could not be read at all.
#
# Ported from upstream's ResponseError in dialect/session.py.
class ResponseError < StandardError
  DEFAULT_MESSAGE = 'Response has failed'

  attr_reader :cause_message

  def initialize(cause, message: DEFAULT_MESSAGE)
    @cause_message = cause
    super("#{message}: #{cause}")
  end
end

# Dialect's HTTP session handler and the request helpers providers are built
# on.
#
# Ported from upstream's dialect/session.py and dialect/providers/soup.py,
# through the soup3 gem: libsoup's own Soup::Session, exactly as upstream
# uses it, rather than the Net::HTTP stand-in an earlier round of this port
# hand-rolled because no Ruby binding for libsoup existed yet.
#
# soup3's Soup::Session has both the async methods upstream awaits from its
# asyncio coroutines and plain synchronous ones (#send_and_read); this uses
# the synchronous one, since BackgroundTask already moves provider calls onto
# a worker thread rather than the GLib main loop, so there is no coroutine to
# suspend here.
#
# Each message carries Soup::MessageFlags::NO_REDIRECT, and redirects are
# followed by hand, in #follow below, rather than through libsoup's own
# built-in following. Measured against the probe server in
# test/drive_dialect.rb: libsoup auto-follows a bodyless GET through as many
# 307/308 hops as it likes (raising Soup::SessionError::TooManyRedirects once
# its own internal cap is hit), but does *not* auto-follow a 307/308 on a
# request that carries a body — it hands the 308 straight back instead of
# resending the body to the new location — because resending a POST body
# without the caller's say-so is exactly the kind of thing an HTTP client
# should not do silently. lingva.dialectapp.org answers its API paths with a
# 308 to the same path with a trailing slash, including on POSTs, so that
# case has to work; handling every redirect the same way, by hand, with one
# hop budget, is simpler than special-casing GET.
#
# One known regression, found while writing this: Net::HTTP's blocking calls
# release Ruby's global VM lock for the syscall, so a BackgroundTask worker
# thread doing a request left the main thread (and its GLib main loop) free to
# keep the UI responsive. soup3's #send_and_read is invoked through
# GObjectIntrospection's generic method invoker, which does not release the
# GVL for the duration of the call — confirmed by running it against a
# same-process loopback server on a second Ruby Thread, which never got
# scheduled to answer until the request timed out (see test/drive_dialect.rb's
# HttpProbe, which now serves from a forked process rather than a Thread for
# exactly this reason). In this app that means the UI can stall for the
# length of a translation request. Fixing it for real means driving
# soup3 asynchronously off the GLib main loop and turning every provider
# method that calls through Session into a callback-based one — a change to
# every provider file and to BackgroundTask's contract that is out of scope
# for this round; it is named here and in the port's notes rather than
# silently shipped as if it were free.
class Session
  USER_AGENT = 'Dialect App'

  # libsoup's one request timeout, covering both connecting and reading.
  # Upstream leaves libsoup's own default; this keeps a hung service from
  # pinning a worker thread forever.
  TIMEOUT = 30

  # Upstream's redirect hop budget, now enforced by #follow rather than by
  # libsoup (see the class comment).
  MAX_REDIRECTS = 5

  # Redirects that keep the original method and body.
  KEEP_METHOD_STATUSES = [307, 308].freeze

  # Redirects that turn the request into a GET.
  REWRITE_METHOD_STATUSES = [301, 302, 303].freeze

  # The status and raw body of a response, the two things the provider helpers
  # read off a finished Soup.Message upstream.
  Response = Data.define(:status, :body)

  # Everything a request needs, so following a redirect is a matter of
  # replacing the url and, where the status demands it, the method and body.
  Request = Data.define(
    :method,
    :url,
    :data,
    :headers,
    :form,
  )

  # The failures a send can raise that are not this app's fault: libsoup's
  # own transport errors (connection refused, DNS failure, TLS, …) come back
  # as a bare GLib::Error (itself a RuntimeError in this binding, so the
  # second entry is redundant for those — it is kept because a URL libsoup's
  # own parser rejects outright, such as an unbalanced IPv6 literal, fails
  # inside Soup::Message.new itself with a plain RuntimeError that is not a
  # GLib::Error at all); SocketError and the Errno constants cover the
  # outcome if the underlying connect ever surfaces as a bare Ruby socket
  # error instead of a wrapped GLib one.
  NETWORK_ERRORS = [GLib::Error, RuntimeError, SocketError, SystemCallError].freeze

  # The process-wide session, matching upstream's Session.get().
  def self.get = @instance ||= new

  # Drops the process-wide session, so a test can install its own.
  def self.reset = @instance = nil

  def initialize
    @soup_session = Soup::Session.new.tap do |session|
      session.timeout = TIMEOUT
    end
  end

  # Sends a request and reads the whole response.
  #
  # Mirrors upstream's SoupProvider.create_message plus
  # Soup.Session.send_and_read_async: +data+ is sent as a form body when
  # +form+ is set and as a JSON body otherwise, and a User-Agent is added
  # unless the caller supplied one.
  def send_and_read(method, url, data: nil, headers: {}, form: false)
    Request.new(method: method, url: url, data: data, headers: headers, form: form).then do |request|
      follow(request, MAX_REDIRECTS)
    end
  rescue *NETWORK_ERRORS => exc
    raise ResponseError.new(exc.message)
  end

  private

    # Performs the request and follows a redirect when the service sends one,
    # until the hop budget runs out — at which point, like upstream, the last
    # redirect response is handed back rather than raised as an error.
    def follow(request, hops)
      perform(request).then do |(headers, response)|
        location_of(request, headers, response).then do |location|
          if location.nil? || hops.zero?
            response
          else
            follow(redirected(request, response.status, location), hops - 1)
          end
        end
      end
    end

    def redirected(request, status, location)
      if KEEP_METHOD_STATUSES.include?(status)
        request.with(url: location)
      else
        request.with(method: 'GET', url: location, data: nil)
      end
    end

    # The absolute target of a redirect, or nil when this was not one. The
    # request's own url, not the message's, is resolved against: libsoup's
    # GUri (Soup::Message#uri) has no Ruby-level stringifier this binding
    # exposes, but the url this method was called with is already the string
    # #redirected needs to resolve a relative Location against.
    def location_of(request, headers, response)
      if redirect?(response.status)
        headers.get_one('Location').then do |location|
          if location
            URI.join(request.url, location).to_s
          end
        end
      end
    end

    def redirect?(status)
      KEEP_METHOD_STATUSES.include?(status) || REWRITE_METHOD_STATUSES.include?(status)
    end

    def perform(request)
      build_message(request).then do |message|
        @soup_session.send_and_read(message).then do |bytes|
          [message.response_headers, Response.new(status: message.status_code, body: bytes.to_s)]
        end
      end
    end

    def build_message(request)
      Soup::Message.new(request.method, request.url).tap do |message|
        message.add_flags(Soup::MessageFlags::NO_REDIRECT)

        request.headers.each { |name, value| message.request_headers.append(name.to_s, value.to_s) }

        unless request.headers.keys.any? { |name| name.to_s.casecmp('User-Agent').zero? }
          message.request_headers.append('User-Agent', USER_AGENT)
        end

        add_body(message, request.data, request.form)
      end
    end

    def add_body(message, data, form)
      if data && !data.empty?
        if form
          GLib::Bytes.new(Soup.form_encode_hash(data).b).then do |bytes|
            message.set_request_body_from_bytes('application/x-www-form-urlencoded', bytes)
          end
        else
          GLib::Bytes.new(JSON.generate(data).b).then do |bytes|
            message.set_request_body_from_bytes('application/json', bytes)
          end
        end
      end
    end
end

# The request helpers every provider shares.
#
# Ported from upstream's SoupProvider in dialect/providers/soup.py. Providers
# override #check_known_errors to turn a service's own error payloads into the
# exceptions in provider_errors.rb.
module SessionHelpers
  # Status codes that should be retried automatically. Providers override this.
  def retry_errors = []

  # Max number of tries for a retryable status.
  def max_retries = 5

  # Checks response data for errors and raises the matching exception.
  # Subclasses implement this; the base behaviour accepts everything.
  def check_known_errors(status, data); end

  # Sends a request and processes the response, applying the retry policy and
  # then the provider's own error checks.
  #
  # Mirrors upstream's SoupProvider.send_and_read_and_process, including its
  # exponential backoff over `retry_errors` and its conversion of transport
  # failures into RequestError.
  def request(method, url, data: nil, headers: {}, form: false, check_common: true, return_json: true)
    begin
      with_retries { session.send_and_read(method, url, data: data, headers: headers, form: form) }
    rescue ResponseError => exc
      raise RequestError, exc.cause_message
    end.then do |response|
      body_of(response, return_json).tap do |data_read|
        if check_common
          check_known_errors(response.status, data_read)
        end
      end
    end
  end

  def get(url, headers: {}, check_common: true, return_json: true)
    request('GET', url, headers: headers, check_common: check_common, return_json: return_json)
  end

  def post(url, data: nil, headers: {}, form: false, check_common: true, return_json: true)
    request(
      'POST',
      url,
      data:         data,
      headers:      headers,
      form:         form,
      check_common: check_common,
      return_json:  return_json,
    )
  end

  def session = Session.get

  private

    def with_retries(&send)
      send.call.then do |first|
        if retry_errors.include?(first.status)
          retrying(first, &send)
        else
          first
        end
      end
    end

    # Retries with exponential backoff, keeping the last response when every
    # try came back with a retryable status.
    def retrying(first, &send)
      1.then do |delay|
        max_retries.times.reduce([first, delay]) do |(response, wait), _try|
          if retry_errors.include?(response.status)
            sleep(wait)
            [send.call, wait * 2]
          else
            [response, wait]
          end
        end.first
      end
    end

    def body_of(response, return_json)
      if return_json
        parse_json(response.body)
      else
        response.body
      end
    end

    def parse_json(body)
      if body.empty?
        {}
      else
        JSON.parse(body)
      end
    end
end
