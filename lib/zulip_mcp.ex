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

  Tools (13 — see `tools/0` for the authoritative list):

    * messaging — `search_messages` (newest-first; returns all in-window
      matches when a time window is given), `get_message`, `send_message`,
      `edit_message`
    * reactions/files — `add_reaction`, `remove_reaction`, `upload_file`
    * discovery — `get_streams`, `get_users`
    * push-mode events — `next_events`, `wait_for_events`
    * agent lifecycle — `register_agent`, `ensure_agent_session`
  """

  use McpServer

  alias ZulipMcp.Client

  # search_messages pagination (GOF-42, per Guppie msg 597326240): when a time
  # window is given we page backwards until we pass the cutoff, so EVERY in-window
  # match is returned — not just the newest page. Bounded for safety.
  @search_page_size 100
  @max_search_pages 25

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
      tool_wait_for_events(),
      tool_register_agent(),
      tool_ensure_agent_session(),
      tool_list_followed_topics(),
      tool_follow_topic(),
      tool_unfollow_topic()
    ]
  end

  # --- Tool: register_agent ---

  defp tool_register_agent do
    %{
      "name" => "register_agent",
      "description" =>
        "Register or update a stable agent profile for Zulip control. Returns a " <>
          "deterministic agent_id (idempotent on agent_name/agent_type/owner_email) that " <>
          "ensure_agent_session consumes. Set stream_name + topic_prefix to control where " <>
          "this agent's session topics live (default prefix \"Agents/Session\").",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agent_name" => %{"type" => "string", "default" => "claude"},
          "agent_type" => %{"type" => "string", "default" => "claude-code"},
          "owner_email" => %{"type" => "string"},
          "stream_name" => %{"type" => "string"},
          "topic_prefix" => %{"type" => "string", "default" => "Agents/Session"},
          "metadata" => %{"type" => "object"}
        }
      }
    }
  end

  # --- Tool: ensure_agent_session ---

  defp tool_ensure_agent_session do
    %{
      "name" => "ensure_agent_session",
      "description" =>
        "Create or refresh the Zulip topic binding for an agent session. Requires an " <>
          "agent_id from register_agent. Returns a deterministic session_id + the bound " <>
          "{stream, topic}; idempotent on agent_id + external_session_id. Posts a one-line " <>
          "lifecycle message into the topic when the session is new or its status changed.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{"type" => "string"},
          "external_session_id" => %{"type" => "string"},
          "project_name" => %{"type" => "string"},
          "project_dir" => %{"type" => "string"},
          "topic_name" => %{"type" => "string"},
          "status" => %{"type" => "string", "default" => "active"},
          "metadata" => %{"type" => "object"}
        },
        "required" => ["agent_id"]
      }
    }
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
          "propagate_mode" => %{
            "type" => "string",
            "enum" => ["change_one", "change_later", "change_all"]
          }
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

  # --- Tool: followed-topic subscriptions (GOF-73) ---

  defp tool_list_followed_topics do
    %{
      "name" => "list_followed_topics",
      "description" =>
        "List the topics this bot follows (Zulip user_topics, visibility_policy=followed). " <>
          "This is the bot's durable, Zulip-managed subscription list — pair it with catch_up " <>
          "to read new messages without time-window sweeps.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  defp tool_follow_topic do
    %{
      "name" => "follow_topic",
      "description" =>
        "Follow a stream topic so it shows in list_followed_topics (and, later, catch_up). " <>
          "Idempotent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "stream" => %{
            "type" => "string",
            "description" => "Stream name (resolved to stream_id internally)"
          },
          "topic" => %{"type" => "string", "description" => "Topic name"}
        },
        "required" => ["stream", "topic"]
      }
    }
  end

  defp tool_unfollow_topic do
    %{
      "name" => "unfollow_topic",
      "description" => "Stop following a stream topic. Idempotent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "stream" => %{"type" => "string", "description" => "Stream name"},
          "topic" => %{"type" => "string", "description" => "Topic name"}
        },
        "required" => ["stream", "topic"]
      }
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
          "is_private. When last_hours / last_days is set, returns ALL matches in that " <>
          "window (paginated server-side) so mention sweeps never silently drop older " <>
          "in-window messages; limit (default 50) applies only when no time window is given.",
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
    cutoff = window_cutoff(args)

    fetched =
      case cutoff do
        nil ->
          # No time window: a single newest-N fetch (N = limit) is enough.
          num_before = Map.get(args, "limit", 50)

          with {:ok, %{"messages" => msgs}} <-
                 Client.get_messages(narrow: narrow, anchor: "newest", num_before: num_before),
               do: {:ok, msgs}

        cutoff_ts ->
          # Time window: page backwards until we pass the cutoff so ALL matches
          # in the window are returned (never relevance/limit-truncated).
          collect_in_window(narrow, cutoff_ts)
      end

    case fetched do
      {:ok, messages} ->
        results =
          messages
          |> then(fn ms -> if cutoff, do: Enum.filter(ms, &(&1["timestamp"] >= cutoff)), else: ms end)
          |> Enum.sort_by(& &1["id"], :desc)

        log_mention_signal(args, "ok", length(results))

        text =
          %{
            "found" => length(results),
            "messages" =>
              Enum.map(results, fn m ->
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
        log_mention_signal(args, "error", inspect(reason))
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
        {:ok,
         [
           %{
             "type" => "text",
             "text" => JSON.encode!(%{"status" => "success", "message_id" => msg_id})
           }
         ]}

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

        {:ok,
         [
           %{
             "type" => "text",
             "text" => JSON.encode!(%{"streams" => compact, "count" => length(compact)})
           }
         ]}

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

        {:ok,
         [
           %{
             "type" => "text",
             "text" => JSON.encode!(%{"users" => compact, "count" => length(compact)})
           }
         ]}

      {:error, reason} ->
        {:error, "get_users failed: #{inspect(reason)}"}
    end
  end

  # --- Followed-topic subscriptions (GOF-73) ---

  def handle_tool_call("list_followed_topics", _args) do
    case Client.get_user_topics() do
      {:ok, %{"user_topics" => topics}} ->
        followed =
          topics
          |> Enum.filter(fn t -> t["visibility_policy"] == 3 end)
          |> Enum.map(fn t -> %{"stream_id" => t["stream_id"], "topic" => t["topic_name"]} end)

        {:ok,
         [
           %{
             "type" => "text",
             "text" => JSON.encode!(%{"followed_topics" => followed, "count" => length(followed)})
           }
         ]}

      {:error, reason} ->
        {:error, "list_followed_topics failed: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("follow_topic", %{"stream" => stream, "topic" => topic}),
    do: set_topic_follow(stream, topic, 3, "follow_topic")

  def handle_tool_call("unfollow_topic", %{"stream" => stream, "topic" => topic}),
    do: set_topic_follow(stream, topic, 0, "unfollow_topic")

  def handle_tool_call("next_events", _args) do
    events = ZulipMcp.EventsLongPollClient.drain()

    {:ok,
     [
       %{
         "type" => "text",
         "text" => JSON.encode!(%{"events" => events, "count" => length(events)})
       }
     ]}
  end

  def handle_tool_call("wait_for_events", args) do
    timeout = Map.get(args, "timeout_ms", 30_000)
    events = ZulipMcp.EventsLongPollClient.wait(timeout)

    {:ok,
     [
       %{
         "type" => "text",
         "text" => JSON.encode!(%{"events" => events, "count" => length(events)})
       }
     ]}
  end

  def handle_tool_call("register_agent", args) do
    {:ok, profile} = ZulipMcp.AgentRegistry.register(args)
    {:ok, [%{"type" => "text", "text" => JSON.encode!(profile)}]}
  end

  def handle_tool_call("ensure_agent_session", %{"agent_id" => _} = args) do
    case ZulipMcp.AgentRegistry.ensure_session(args) do
      {:ok, session, change} ->
        # Shell side effect: announce the session in its topic, but only when
        # it's new or its status changed, so refresh calls don't spam.
        if change == :new do
          _ =
            Client.send_message(
              "stream",
              session["stream"],
              session["topic"],
              "🟢 `#{session["agent_name"]}` session **#{session["status"]}** (session_id `#{session["session_id"]}`)"
            )
        end

        {:ok,
         [
           %{
             "type" => "text",
             "text" => JSON.encode!(Map.put(session, "lifecycle_posted", change == :new))
           }
         ]}

      {:error, :unknown_agent} ->
        {:error, "ensure_agent_session failed: unknown agent_id — call register_agent first"}
    end
  end

  # Fallback for unknown tool names — clearer error string than letting
  # FunctionClauseError bubble up to McpServer's rescue block.
  def handle_tool_call(name, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  # --- Followed-topic helpers (GOF-73) ---

  defp set_topic_follow(stream, topic, policy, tool) do
    with {:ok, stream_id} <- resolve_stream_id(stream),
         {:ok, _resp} <- Client.set_topic_visibility(stream_id, topic, policy) do
      {:ok,
       [
         %{
           "type" => "text",
           "text" =>
             JSON.encode!(%{
               "ok" => true,
               "stream" => stream,
               "topic" => topic,
               "visibility_policy" => policy
             })
         }
       ]}
    else
      {:error, reason} -> {:error, "#{tool} failed: #{inspect(reason)}"}
    end
  end

  # Agents work in stream *names*; user_topics needs the numeric stream_id.
  defp resolve_stream_id(stream_name) do
    case Client.get_streams() do
      {:ok, %{"streams" => streams}} ->
        case Enum.find(streams, fn s -> s["name"] == stream_name end) do
          nil -> {:error, "unknown stream: #{stream_name}"}
          s -> {:ok, s["stream_id"]}
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  # Emit a grep-able runlog line for is_mentioned searches so GOF-44's
  # acceptance gate (">=1 fleet-day with zero is_mentioned timeouts") is
  # measurable. No-op for non-mention searches; stderr keeps it out of the
  # JSON-RPC stdout stream.
  defp log_mention_signal(%{"is_mentioned" => true}, status, detail) do
    IO.puts(:stderr, "[zulip-mcp] event=is_mentioned_search status=#{status} detail=#{inspect(detail)}")
  end

  defp log_mention_signal(_args, _status, _detail), do: :ok

  # Unix-second cutoff from last_hours / last_days, or nil if no time window.
  # Zulip's narrow has no native time operator, so we window client-side.
  defp window_cutoff(args) do
    cond do
      h = args["last_hours"] -> System.system_time(:second) - h * 3600
      d = args["last_days"] -> System.system_time(:second) - d * 86_400
      true -> nil
    end
  end

  # Page backwards from newest until we cross the cutoff (or exhaust the stream
  # / hit the page cap), accumulating de-duplicated messages. This guarantees
  # every in-window match is returned even when there's more than one page of
  # them — the fix for Guppie's lossy-mention-narrow report (msg 597326240).
  defp collect_in_window(narrow, cutoff) do
    collect_in_window(narrow, cutoff, "newest", %{}, 0)
  end

  defp collect_in_window(_narrow, _cutoff, _anchor, acc, page) when page >= @max_search_pages do
    {:ok, Map.values(acc)}
  end

  defp collect_in_window(narrow, cutoff, anchor, acc, page) do
    case Client.get_messages(narrow: narrow, anchor: anchor, num_before: @search_page_size, num_after: 0) do
      {:ok, %{"messages" => []}} ->
        {:ok, Map.values(acc)}

      {:ok, %{"messages" => msgs}} ->
        acc = Enum.reduce(msgs, acc, fn m, a -> Map.put(a, m["id"], m) end)
        oldest_id = msgs |> Enum.map(& &1["id"]) |> Enum.min()
        oldest_ts = msgs |> Enum.map(& &1["timestamp"]) |> Enum.min()

        cond do
          # Fewer than a full page => no older messages remain.
          length(msgs) < @search_page_size -> {:ok, Map.values(acc)}
          # Oldest message on this page predates the window => fully covered.
          oldest_ts < cutoff -> {:ok, Map.values(acc)}
          # Keep walking older. anchor=oldest_id re-includes that one message
          # (deduped by the acc map), so we advance page_size-1 per round.
          true -> collect_in_window(narrow, cutoff, oldest_id, acc, page + 1)
        end

      {:error, reason} ->
        # Don't fail the whole search on a later page error — return what we
        # already gathered; only surface the error if we have nothing at all.
        if map_size(acc) == 0, do: {:error, reason}, else: {:ok, Map.values(acc)}
    end
  end
end
