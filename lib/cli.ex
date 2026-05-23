defmodule ZulipMcp.CLI do
  @moduledoc """
  Escript entrypoint. Boots Req's app (so the underlying httpc connection
  pool is up) and hands control to `ZulipMcp.serve/0`, which reads
  JSON-RPC requests from stdin and writes responses to stdout — the
  transport Claude Code expects for stdio MCP servers.
  """

  def main(_argv) do
    {:ok, _} = Application.ensure_all_started(:req)
    ZulipMcp.serve()
  end
end
