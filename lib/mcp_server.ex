defmodule McpServer do
  @moduledoc """
  Reusable single-file MCP (Model Context Protocol) server behaviour.

  Implements JSON-RPC 2.0 over stdio per the Anthropic MCP spec, so any
  module that `use`s this behaviour gets a working stdio MCP server with
  only `server_info/0`, `tools/0`, and `handle_tool_call/2` implemented.

  Modeled on the Picaso `mcp_server.ex` design (per Zulip
  `#harness-engineering > Custom Zulip MCP` msg 596042166) — single file,
  zero deps beyond built-in `JSON` (Elixir 1.18+).

  ## Usage

      defmodule MyMcp do
        use McpServer

        @impl McpServer
        def server_info, do: %{name: "my-mcp", version: "0.1.0"}

        @impl McpServer
        def tools do
          [
            %{
              "name" => "echo",
              "description" => "Echo back the input",
              "inputSchema" => %{
                "type" => "object",
                "properties" => %{"text" => %{"type" => "string"}},
                "required" => ["text"]
              }
            }
          ]
        end

        @impl McpServer
        def handle_tool_call("echo", %{"text" => t}) do
          {:ok, [%{"type" => "text", "text" => t}]}
        end
      end

  Then call `MyMcp.serve()` from an escript main or a Mix task — it will
  read JSON-RPC requests from stdin one line at a time and write responses
  to stdout. Logs go to stderr.
  """

  @callback server_info() :: %{name: String.t(), version: String.t()}
  @callback tools() :: [map()]
  @callback handle_tool_call(name :: String.t(), arguments :: map()) ::
              {:ok, content :: [map()]} | {:error, message :: String.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour McpServer
      require Logger

      def serve do
        McpServer.serve_loop(__MODULE__)
      end

      defoverridable serve: 0
    end
  end

  @protocol_version "2024-11-05"

  @doc """
  Read-eval-print loop. Reads one JSON-RPC line at a time from stdin,
  dispatches to the implementing module, and writes the response to
  stdout. Stops on EOF.

  Each line is a complete JSON-RPC message (Content-Length framing is
  not used in this transport — Claude Code's stdio MCP transport is
  newline-delimited).
  """
  def serve_loop(impl) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        log_stderr("read error: #{inspect(reason)}")
        :error

      line when is_binary(line) ->
        handle_line(line, impl)
        serve_loop(impl)
    end
  end

  defp handle_line(line, impl) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :skip
    else
      case JSON.decode(trimmed) do
        {:ok, request} ->
          response = dispatch(request, impl)
          write_response(response)

        {:error, reason} ->
          log_stderr("JSON decode error: #{inspect(reason)} for line: #{inspect(trimmed)}")
          write_response(error_response(nil, -32700, "Parse error"))
      end
    end
  end

  defp dispatch(%{"method" => "initialize", "id" => id}, impl) do
    success_response(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => impl.server_info()
    })
  end

  defp dispatch(%{"method" => "notifications/initialized"}, _impl) do
    # Notifications don't get responses
    :no_response
  end

  defp dispatch(%{"method" => "ping", "id" => id}, _impl) do
    success_response(id, %{})
  end

  defp dispatch(%{"method" => "tools/list", "id" => id}, impl) do
    success_response(id, %{"tools" => impl.tools()})
  end

  defp dispatch(%{"method" => "tools/call", "id" => id, "params" => params}, impl) do
    name = params["name"]
    args = params["arguments"] || %{}

    try do
      case impl.handle_tool_call(name, args) do
        {:ok, content} ->
          success_response(id, %{"content" => content, "isError" => false})

        {:error, message} ->
          success_response(id, %{
            "content" => [%{"type" => "text", "text" => message}],
            "isError" => true
          })
      end
    rescue
      e ->
        log_stderr("tool call crashed: #{Exception.format(:error, e, __STACKTRACE__)}")

        success_response(id, %{
          "content" => [
            %{"type" => "text", "text" => "Tool crashed: #{Exception.message(e)}"}
          ],
          "isError" => true
        })
    end
  end

  defp dispatch(%{"id" => id, "method" => method}, _impl) do
    error_response(id, -32601, "Method not found: #{method}")
  end

  defp dispatch(_other, _impl), do: :no_response

  defp success_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp write_response(:no_response), do: :ok

  defp write_response(resp) do
    json = JSON.encode!(resp)
    IO.puts(json)
  end

  defp log_stderr(msg) do
    IO.puts(:stderr, "[McpServer] #{msg}")
  end
end
