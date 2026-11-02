# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
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
# Ported from upstream's dialect/session.py and dialect/providers/soup.py.
#
# Upstream uses libsoup's Soup.Session with send_and_read_async, awaited from
# asyncio coroutines on the GLib main loop. The Ruby bindings ship no libsoup
# bindings, so requests go through Net::HTTP instead, and the asynchrony moves
# out of the provider methods and into BackgroundTask, which runs them on a
# worker thread and hands the result back on the main loop. Provider methods
# are therefore blocking calls that must not be made from the main thread.
class Session
  USER_AGENT = 'Dialect App'

  # Default timeouts, in seconds. libsoup has its own defaults; these keep a
  # hung service from pinning a worker thread forever.
  OPEN_TIMEOUT = 15
  READ_TIMEOUT = 30

  # Soup.Session follows redirects on its own, and services the providers talk
  # to rely on it: lingva.dialectapp.org answers its API paths with a 308 to
  # the same path with a trailing slash. Net::HTTP follows nothing, so the
  # session does it here, with the browser rules libsoup implements.
  MAX_REDIRECTS = 5

  # Redirects that keep the original method and body.
  KEEP_METHOD_STATUSES = [307, 308].freeze

  # Redirects that turn the request into a GET.
  REWRITE_METHOD_STATUSES = [301, 302, 303].freeze

  # The status and raw body of a response, the two things the provider helpers
  # read off a finished Soup.Message upstream.
  Response = Data.define(:status, :body)

  # A finished request, carrying the Location header so a redirect can be
  # followed without exposing it to the providers.
  Result = Data.define(:response, :location)

  # Everything a request needs, so following a redirect is a matter of
  # replacing the url and, where the status demands it, the method.
  Request = Data.define(
    :method,
    :url,
    :data,
    :headers,
    :form,
  )

  # The network failures Net::HTTP can raise, which upstream sees as a
  # GLib::Error out of libsoup and converts to RequestError.
  NETWORK_ERRORS = [
    SocketError,
    OpenSSL::SSL::SSLError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::ETIMEDOUT,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::HTTPBadResponse,
    IOError,
  ].freeze

  # The process-wide session, matching upstream's Session.get().
  def self.get = @instance ||= new

  # Drops the process-wide session, so a test can install its own.
  def self.reset = @instance = nil

  # Sends a request and reads the whole response.
  #
  # Mirrors upstream's SoupProvider.create_message plus
  # Soup.Session.send_and_read_async: +data+ is sent as a form body when
  # +form+ is set and as a JSON body otherwise, and a User-Agent is added
  # unless the caller supplied one.
  def send_and_read(method, url, data: nil, headers: {}, form: false)
    Request.new(
      method:  method,
      url:     url,
      data:    data,
      headers: headers,
      form:    form,
    ).then { |request| follow(request, MAX_REDIRECTS) }
  rescue URI::InvalidURIError => exc
    raise ResponseError.new(exc.message)
  rescue *NETWORK_ERRORS => exc
    raise ResponseError.new(exc.message)
  end

  private

    # Performs the request and follows a redirect when the service sends one,
    # until the hop budget runs out.
    def follow(request, hops)
      URI.parse(request.url).then do |uri|
        perform(uri, net_request(request, uri)).then do |result|
          redirect_from(
            result,
            uri,
            request,
            hops,
          ) || result.response
        end
      end
    end

    # The response to the redirect target, or nil when this was not a
    # redirect or the hops ran out.
    def redirect_from(result, uri, request, hops)
      location_of(result, uri).then do |location|
        unless location.nil? || hops.zero?
          follow(redirected(request, result.response.status, location), hops - 1)
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

    # The absolute target of a redirect, or nil when this was not one.
    def location_of(result, uri)
      if redirect?(result.response.status) && !result.location.nil?
        URI.join(uri, result.location).to_s
      end
    end

    def redirect?(status)
      KEEP_METHOD_STATUSES.include?(status) || REWRITE_METHOD_STATUSES.include?(status)
    end

    def net_request(request, uri)
      Net::HTTP.const_get(request.method.to_s.capitalize).new(uri).tap do |net|
        request.headers.each { |name, value| net[name] = value }

        unless request.headers.keys.any? { |name| name.to_s.casecmp('User-Agent').zero? }
          net['User-Agent'] = USER_AGENT
        end

        add_body(net, request.data, request.form)
      end
    end

    def add_body(net, data, form)
      if data && !data.empty?
        if form
          net.set_form_data(data)
        else
          net['Content-Type'] = 'application/json'
          net.body = JSON.generate(data)
        end
      end
    end

    def perform(uri, net)
      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl:      uri.scheme == 'https',
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT,
      ) do |http|
        http.request(net).then do |response|
          Result.new(
            response: Response.new(status: response.code.to_i, body: response.body.to_s),
            location: response['Location'],
          )
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
