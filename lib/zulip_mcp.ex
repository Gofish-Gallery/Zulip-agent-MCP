defmodule ZulipMcp do
  @moduledoc """
  Custom Zulip MCP server — Elixir implementation.

  Why we wrote our own (per [GOF-42](https://linear.app/gofishgallery/issue/GOF-42)):

    * The third-party `akougkas/zulipchat-mcp` we share across agents has
      a `sort_by=newest` bug — silently returns OLDEST-K instead of
      NEWEST-K, so agents miss recent messages on every poll.
    * The global `is_mentioned: true` narrow times out at 15 s, which
      caused me (Armstrong) to miss Luke's direct ping for ~20 min on
      2026-05-23 (Zulip msg 597317550). The third-party MCP doesn't
      retry or widen on timeout.
    * No push semantics — bots only see new messages on the next poll.
      Zulip exposes a long-poll `events` API; the third-party MCP
      doesn't use it.

  This module implements the MCP tool surface that mirrors what the
  third-party MCP exposes, so a drop-in swap is possible. Underneath,
  `sort_by=newest` actually works (we use Zulip's natural
  `anchor=newest` paging) and there's a path for push-mode wakeups via
  `EventsLongPollClient`.

  Tools (first wave, more to come — see `tools/0` below):

    * `search_messages` — keyword + narrow search, newest-first by
      default
    * `get_message` — fetch one message by id
    * `send_message` — stream or private message
  """

  use McpServer

  alias ZulipMcp.Client

  @impl McpServer
  def server_info, do: %{name: "zulip-mcp-ex", version: "0.1.0"}

  @impl McpServer
  def tools do
    [
      tool_search_messages(),
      tool_get_message(),
      tool_send_message(),
      tool_edit_message(),
      tool_upload_file(),
      tool_add_reaction(),
      tool_remove_reaction(),
      tool_get_streams(),
      tool_get_users(),
      tool_next_events(),
      tool_wait_for_events()
    ]
  end

  # --- Tool: edit_message ---

  defp tool_edit_message do
    %{
      "name" => "edit_message",
      "description" =>
        "Edit a message you've sent. Pass `content` to change the body, `topic` to move " <>
          "the message between topics (stream messages only). `propagate_mode` is one of " <>
          "\"change_one\" (default), \"change_later\", \"change_all\".",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message_id" => %{"type" => "integer"},
          "content" => %{"type" => "string"},
          "topic" => %{"type" => "string"},
          "propagate_mode" => %{"type" => "string", "enum" => ["change_one", "change_later", "change_all"]}
        },
        "required" => ["message_id"]
      }
    }
  end

  # --- Tool: upload_file ---

  defp tool_upload_file do
    %{
      "name" => "upload_file",
      "description" =>
        "Upload a local file to Zulip's user_uploads endpoint. Returns the URI you can " <>
          "embed in a message as [filename](uri). Picaso's #1 daily pain point on the " <>
          "third-party MCP — first-class here so screenshots / images / docs don't need " <>
          "raw curl.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute path on the agent host"}
        },
        "required" => ["path"]
      }
    }
  end

  # --- Tool: add_reaction ---

  defp tool_add_reaction do
    %{
      "name" => "add_reaction",
      "description" =>
        "Add an emoji reaction to a message. `emoji_name` is the Zulip name WITHOUT " <>
          "surrounding colons (e.g. \"tropical_fish\", not \":tropical_fish:\"). Fixes the " <>
          "third-party MCP's tiny emoji allowlist — anything Zulip itself accepts works here.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message_id" => %{"type" => "integer"},
          "emoji_name" => %{"type" => "string"}
        },
        "required" => ["message_id", "emoji_name"]
      }
    }
  end

  # --- Tool: remove_reaction ---

  defp tool_remove_reaction do
    %{
      "name" => "remove_reaction",
      "description" => "Remove an emoji reaction you previously added.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message_id" => %{"type" => "integer"},
          "emoji_name" => %{"type" => "string"}
        },
        "required" => ["message_id", "emoji_name"]
      }
    }
  end

  # --- Tool: get_streams ---

  defp tool_get_streams do
    %{
      "name" => "get_streams",
      "description" => "List streams the bot can see.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  # --- Tool: get_users ---

  defp tool_get_users do
    %{
      "name" => "get_users",
      "description" => "List users in the realm (active by default).",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  # --- Tool: next_events (push-mode dequeue) ---

  defp tool_next_events do
    %{
      "name" => "next_events",
      "description" =>
        "Return any events buffered by the long-poll client since the last call, " <>
          "and clear the buffer. Non-blocking. Returns [] if no events are queued. " <>
          "This is the push-mode primitive — typical wake latency from new-message-on-Zulip " <>
          "to event-visible-here is < 1 s, vs the ~10 min cron poll the third-party MCP uses.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  # --- Tool: wait_for_events ---

  defp tool_wait_for_events do
    %{
      "name" => "wait_for_events",
      "description" =>
        "Block until at least one event arrives, or `timeout_ms` (default 30000) elapses. " <>
          "Returns the same shape as next_events. Use this when an agent is idle and wants " <>
          "to wake on the first message without burning a tick to poll.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "timeout_ms" => %{"type" => "integer", "default" => 30_000}
        }
      }
    }
  end

  # --- Tool: search_messages ---

  defp tool_search_messages do
    %{
      "name" => "search_messages",
      "description" =>
        "Search Zulip messages with filters. Returns newest-first by default — " <>
          "unlike the third-party MCP, sort_by=newest actually works here. " <>
          "Provide any combination of stream, topic, sender, query, is_mentioned, " <>
          "is_private. Use last_hours / last_days for time window. limit defaults to 50.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "stream" => %{"type" => "string"},
          "topic" => %{"type" => "string"},
          "sender" => %{"type" => "string", "description" => "Email of the sender"},
          "query" => %{"type" => "string", "description" => "Full-text keyword search"},
          "is_mentioned" => %{"type" => "boolean"},
          "is_private" => %{"type" => "boolean"},
          "is_starred" => %{"type" => "boolean"},
          "has_link" => %{"type" => "boolean"},
          "has_image" => %{"type" => "boolean"},
          "has_attachment" => %{"type" => "boolean"},
          "last_hours" => %{"type" => "integer"},
          "last_days" => %{"type" => "integer"},
          "limit" => %{"type" => "integer", "default" => 50}
        }
      }
    }
  end

  # --- Tool: get_message ---

  defp tool_get_message do
    %{
      "name" => "get_message",
      "description" => "Retrieve a single message by ID.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"message_id" => %{"type" => "integer"}},
        "required" => ["message_id"]
      }
    }
  end

  # --- Tool: send_message ---

  defp tool_send_message do
    %{
      "name" => "send_message",
      "description" => "Send a stream or private message.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "type" => %{"type" => "string", "enum" => ["stream", "private"]},
          "to" => %{"type" => "string"},
          "topic" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["type", "to", "content"]
      }
    }
  end

  # --- Tool-call dispatch (grouped) ---
  #
  # Elixir wants all clauses of a given function/arity grouped together, so
  # the dispatch clauses live here as a block, even though it splits each
  # tool's "definition + handler" pair across the file.

  @impl McpServer
  def handle_tool_call("search_messages", args) do
    narrow = build_narrow(args)
    num_before = Map.get(args, "limit", 50)

    case Client.get_messages(narrow: narrow, anchor: "newest", num_before: num_before) do
      {:ok, %{"messages" => messages}} ->
        filtered = messages |> filter_by_time(args) |> Enum.reverse()

        text =
          %{
            "found" => length(filtered),
            "messages" =>
              Enum.map(filtered, fn m ->
                %{
                  "id" => m["id"],
                  "sender" => m["sender_full_name"],
                  "email" => m["sender_email"],
                  "timestamp" => m["timestamp"],
                  "stream" => m["display_recipient"],
                  "topic" => m["subject"],
                  "content" => m["content"]
                }
              end)
          }
          |> JSON.encode!()

        {:ok, [%{"type" => "text", "text" => text}]}

      {:error, reason} ->
        {:error, "search_messages failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("get_message", %{"message_id" => id}) do
    case Client.get_message(id) do
      {:ok, %{"message" => msg}} ->
        text = JSON.encode!(msg)
        {:ok, [%{"type" => "text", "text" => text}]}

      {:error, reason} ->
        {:error, "get_message failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("send_message", %{"type" => type, "to" => to, "content" => content} = args) do
    topic = Map.get(args, "topic")

    case Client.send_message(type, to, topic, content) do
      {:ok, %{"id" => msg_id}} ->
        {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"status" => "success", "message_id" => msg_id})}]}

      {:error, reason} ->
        {:error, "send_message failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("edit_message", %{"message_id" => id} = args) do
    opts =
      []
      |> maybe_kw(:content, args["content"])
      |> maybe_kw(:topic, args["topic"])
      |> maybe_kw(:propagate_mode, args["propagate_mode"])

    case Client.update_message(id, opts) do
      {:ok, _} -> {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"status" => "success"})}]}
      {:error, reason} -> {:error, "edit_message failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("upload_file", %{"path" => path}) do
    case Client.upload_file(path) do
      {:ok, %{"uri" => uri} = resp} ->
        markdown = "[#{Path.basename(path)}](#{uri})"

        {:ok,
         [%{"type" => "text", "text" => JSON.encode!(Map.put(resp, "markdown_link", markdown))}]}

      {:error, reason} ->
        {:error, "upload_file failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("add_reaction", %{"message_id" => id, "emoji_name" => emoji}) do
    case Client.add_reaction(id, emoji) do
      {:ok, _} -> {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"status" => "success"})}]}
      {:error, reason} -> {:error, "add_reaction failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("remove_reaction", %{"message_id" => id, "emoji_name" => emoji}) do
    case Client.remove_reaction(id, emoji) do
      {:ok, _} -> {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"status" => "success"})}]}
      {:error, reason} -> {:error, "remove_reaction failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("get_streams", _args) do
    case Client.get_streams() do
      {:ok, %{"streams" => streams}} ->
        compact =
          Enum.map(streams, fn s ->
            %{"id" => s["stream_id"], "name" => s["name"], "description" => s["description"]}
          end)

        {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"streams" => compact, "count" => length(compact)})}]}

      {:error, reason} ->
        {:error, "get_streams failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("get_users", _args) do
    case Client.get_users() do
      {:ok, %{"members" => members}} ->
        compact =
          Enum.map(members, fn m ->
            %{
              "user_id" => m["user_id"],
              "email" => m["email"],
              "full_name" => m["full_name"],
              "is_bot" => m["is_bot"],
              "is_active" => m["is_active"]
            }
          end)

        {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"users" => compact, "count" => length(compact)})}]}

      {:error, reason} ->
        {:error, "get_users failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("next_events", _args) do
    events = ZulipMcp.EventsLongPollClient.drain()
    {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"events" => events, "count" => length(events)})}]}
  end

  def handle_tool_call("wait_for_events", args) do
    timeout = Map.get(args, "timeout_ms", 30_000)
    events = ZulipMcp.EventsLongPollClient.wait(timeout)
    {:ok, [%{"type" => "text", "text" => JSON.encode!(%{"events" => events, "count" => length(events)})}]}
  end

  # Fallback for unknown tool names — clearer error string than letting
  # FunctionClauseError bubble up to McpServer's rescue block.
  def handle_tool_call(name, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  defp maybe_kw(kw, _key, nil), do: kw
  defp maybe_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # --- Narrow construction ---

  defp build_narrow(args) do
    []
    |> maybe_narrow(args, "stream", "stream")
    |> maybe_narrow(args, "topic", "topic")
    |> maybe_narrow(args, "sender", "sender")
    |> maybe_narrow(args, "query", "search")
    |> maybe_narrow_bool(args, "is_mentioned", "is", "mentioned")
    |> maybe_narrow_bool(args, "is_private", "is", "private")
    |> maybe_narrow_bool(args, "is_starred", "is", "starred")
    |> maybe_narrow_bool(args, "has_link", "has", "link")
    |> maybe_narrow_bool(args, "has_image", "has", "image")
    |> maybe_narrow_bool(args, "has_attachment", "has", "attachment")
  end

  defp maybe_narrow(narrow, args, key, operator) do
    case Map.get(args, key) do
      nil -> narrow
      "" -> narrow
      value -> narrow ++ [{operator, value}]
    end
  end

  defp maybe_narrow_bool(narrow, args, key, operator, operand) do
    case Map.get(args, key) do
      true -> narrow ++ [{operator, operand}]
      _ -> narrow
    end
  end

  # Apply last_hours / last_days client-side. Zulip's narrow doesn't have
  # a native time operator, so we fetch newest-first and trim to the
  # requested window.
  defp filter_by_time(messages, args) do
    cond do
      hours = args["last_hours"] -> cutoff_filter(messages, hours * 3600)
      days = args["last_days"] -> cutoff_filter(messages, days * 86_400)
      true -> messages
    end
  end

  defp cutoff_filter(messages, seconds) do
    cutoff = System.system_time(:second) - seconds
    Enum.filter(messages, &(&1["timestamp"] >= cutoff))
  end
end
