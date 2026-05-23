defmodule ZulipMcp.CLI do
  @moduledoc """
  Escript entrypoint. Boots Req's app (so the underlying httpc connection
  pool is up) and hands control to `ZulipMcp.serve/0`, which reads
  JSON-RPC requests from stdin and writes responses to stdout — the
  transport Claude Code expects for stdio MCP servers.
  """

  def main(_argv) do
    {:ok, _} = Application.ensure_all_started(:req)

    # Start the long-poll client in the background so push-mode events
    # are buffered for next_events / wait_for_events tool calls. If it
    # fails (e.g. no Zulip creds), log + continue — the synchronous
    # tools (search_messages, send_message) still work without it.
    case ZulipMcp.EventsLongPollClient.start_link([]) do
      {:ok, _pid} ->
        IO.puts(:stderr, "[ZulipMcp] EventsLongPollClient up — push mode enabled")

      {:error, reason} ->
        IO.puts(:stderr, "[ZulipMcp] EventsLongPollClient failed to start: #{inspect(reason)}. Synchronous tools still available.")
    end

    ZulipMcp.serve()
  end
end
