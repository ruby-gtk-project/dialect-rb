# frozen_string_literal: true

require 'gtk4'

# Runs blocking work off the main loop and delivers the result back on it.
#
# Ported from upstream's dialect/asyncio.py.
#
# Upstream's `background_task` decorator wraps an async function so it can be
# used as a signal handler, handing the coroutine to
# Gio.Application.create_asyncio_task. The Ruby bindings have no asyncio
# integration and the provider methods here are blocking Net::HTTP calls, so
# the port runs the work on a Ruby thread and marshals the outcome back onto
# the GLib main loop with an idle callback. That keeps the contract a signal
# handler needs: the call returns immediately, and the callbacks run on the
# main thread, where it is safe to touch widgets.
#
# Like upstream's decorator, the block's value is not available to the caller;
# it reaches the +on_success+ callback instead.
class BackgroundTask
  # Starts a task immediately.
  #
  #   BackgroundTask.run(on_success: ->(t) { show(t) }, on_error: method(:fail)) do
  #     provider.translate(request)
  #   end
  def self.run(on_success: nil, on_error: nil, &work)
    new(on_success: on_success, on_error: on_error, &work).start
  end

  def initialize(on_success: nil, on_error: nil, &work)
    @work = work
    @on_success = on_success
    @on_error = on_error
    @mutex = Mutex.new
    @state = :pending
    @delivered = false
    @cancelled = false
  end

  def start
    @thread = Thread.new do
      begin
        finish(:success, @work.call)
      rescue StandardError => exc
        finish(:error, exc)
      end
    end

    self
  end

  # Abandons the result. The worker thread is left to finish on its own, since
  # a half-sent HTTP request has no safe point to be killed at, but nothing is
  # delivered once a task is cancelled.
  def cancel
    @mutex.synchronize { @cancelled = true }
    self
  end

  def cancelled? = @mutex.synchronize { @cancelled }
  def pending? = @mutex.synchronize { @state == :pending }

  # Blocks until the work is done and delivers its outcome inline, for callers
  # with no main loop running, such as specs and the search provider.
  def wait
    @thread&.join
    deliver
    self
  end

  private

    def finish(state, value)
      @mutex.synchronize do
        @state = state
        @value = value
      end

      GLib::Idle.add do
        deliver
        GLib::Source::REMOVE
      end
    end

    # Hands the outcome to its callback, exactly once. An error with no
    # +on_error+ callback is re-raised rather than swallowed, so a mistake
    # inside a task is not lost.
    def deliver
      claim.then do |state, value|
        case state
        when :success then @on_success&.call(value)
        when :error
          if @on_error
            @on_error.call(value)
          else
            raise value
          end
        end
      end
    end

    # The outcome, or [nil, nil] when there is nothing left to deliver.
    def claim
      @mutex.synchronize do
        if @state == :pending || @cancelled || @delivered
          [nil, nil]
        else
          @delivered = true
          [@state, @value]
        end
      end
    end
end
