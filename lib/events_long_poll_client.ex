defmodule ZulipMcp.EventsLongPollClient do
  @moduledoc """
  Push-mode Zulip event subscriber. Registers an event queue with Zulip
  on startup, then long-polls `/api/v1/events` in a loop in a dedicated
  Task. Events are accumulated in the GenServer's mailbox and made
  available to callers via `drain/1` (non-blocking) or `wait/2`
  (blocking up to a timeout).

  Why this matters: the third-party MCP polls Zulip on a cron schedule.
  With a default loop tick of ~10 min, a new mention can sit unread for
  almost the whole interval. Long-polling lets us subscribe once and
  receive events the moment Zulip emits them — typical wake latency is
  < 1 s on a busy stream.

  This is a v1: it tracks message events globally and buffers them as
  a list. A future revision could:

    * fan events out to multiple subscribers via `Registry`,
    * narrow registration by stream/topic to cut bandwidth,
    * persist `last_event_id` across restarts so we don't miss messages
      during reconnect.

  ## Usage

      {:ok, _pid} = EventsLongPollClient.start_link([])
      EventsLongPollClient.drain()
      # => [%{"type" => "message", "message" => %{...}}, ...]

      # Or block until an event arrives (or timeout):
      EventsLongPollClient.wait(5_000)
  """

  use GenServer
  require Logger

  alias ZulipMcp.Client

  # --- Public API ---

  @doc """
  Start the client. Registers a queue and begins long-polling
  immediately.

  Options:
    * `:event_types` — list of Zulip event types to subscribe to.
      Defaults to `["message"]` (the only one the MCP needs today).
    * `:name` — GenServer name. Defaults to the module name so the
      client is a singleton per BEAM node.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return all buffered events and clear the buffer. Non-blocking.
  """
  def drain(server \\ __MODULE__) do
    GenServer.call(server, :drain)
  end

  @doc """
  Block until at least one event is available, up to `timeout_ms`.
  Returns the same shape as `drain/1`. If the timeout elapses with no
  event, returns `[]`.
  """
  def wait(server \\ __MODULE__, timeout_ms) do
    GenServer.call(server, {:wait, timeout_ms}, timeout_ms + 1_000)
  end

  @doc """
  Inspection hook — current queue_id + last_event_id + buffer length.
  Useful for the MCP `events_status` tool.
  """
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    event_types = Keyword.get(opts, :event_types, ["message"])

    case Client.register_event_queue(event_types) do
      {:ok, %{"queue_id" => queue_id, "last_event_id" => last_id}} ->
        state = %{
          queue_id: queue_id,
          last_event_id: last_id,
          buffer: [],
          waiters: [],
          poller: nil
        }

        {:ok, schedule_poll(state)}

      {:error, reason} ->
        Logger.error("EventsLongPollClient: register failed: #{inspect(reason)}")
        {:stop, {:register_failed, reason}}
    end
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, Enum.reverse(state.buffer), %{state | buffer: []}}
  end

  def handle_call({:wait, timeout_ms}, from, state) do
    case state.buffer do
      [] ->
        timer = Process.send_after(self(), {:waiter_timeout, from}, timeout_ms)
        {:noreply, %{state | waiters: [{from, timer} | state.waiters]}}

      buffered ->
        {:reply, Enum.reverse(buffered), %{state | buffer: []}}
    end
  end

  def handle_call(:status, _from, state) do
    info = %{
      queue_id: state.queue_id,
      last_event_id: state.last_event_id,
      buffered: length(state.buffer),
      waiters: length(state.waiters)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:poll_result, {:ok, events, new_last_id}}, state) do
    {state, _replied} =
      Enum.reduce(events, {state, false}, fn event, {acc, replied?} ->
        acc = %{acc | buffer: [event | acc.buffer]}
        # If any waiters are parked, reply to the first one immediately.
        case {replied?, acc.waiters} do
          {false, [{from, timer} | rest]} ->
            Process.cancel_timer(timer)
            GenServer.reply(from, Enum.reverse(acc.buffer))
            {%{acc | buffer: [], waiters: rest}, true}

          _ ->
            {acc, replied?}
        end
      end)

    {:noreply, schedule_poll(%{state | last_event_id: new_last_id})}
  end

  def handle_info({:poll_result, {:error, reason}}, state) do
    # Re-register on certain errors (BAD_EVENT_QUEUE_ID is the canonical
    # one — happens if the queue expired server-side). Otherwise back off
    # 1s and retry, so we don't hot-loop on transient network errors.
    case reason do
      {:zulip_error, "Bad event queue ID:" <> _} ->
        Logger.warning("EventsLongPollClient: queue expired, re-registering")
        {:ok, %{"queue_id" => q, "last_event_id" => l}} = Client.register_event_queue(["message"])
        {:noreply, schedule_poll(%{state | queue_id: q, last_event_id: l})}

      other ->
        Logger.warning("EventsLongPollClient: poll error #{inspect(other)}, retrying in 1s")
        Process.send_after(self(), :retry_poll, 1_000)
        {:noreply, state}
    end
  end

  def handle_info(:retry_poll, state) do
    {:noreply, schedule_poll(state)}
  end

  def handle_info({:waiter_timeout, from}, state) do
    GenServer.reply(from, [])
    {:noreply, %{state | waiters: List.keydelete(state.waiters, from, 0)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Internal ---

  defp schedule_poll(state) do
    parent = self()
    %{queue_id: q, last_event_id: l} = state

    poller =
      Task.async(fn ->
        result =
          case Client.get_events(q, l) do
            {:ok, %{"events" => events}} ->
              new_last = events |> Enum.map(& &1["id"]) |> Enum.max(fn -> l end)
              {:ok, events, new_last}

            {:error, reason} ->
              {:error, reason}
          end

        send(parent, {:poll_result, result})
      end)

    %{state | poller: poller}
  end
end
