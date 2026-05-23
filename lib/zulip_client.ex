defmodule ZulipMcp.Client do
  @moduledoc """
  Thin Zulip REST API client.

  Auth comes from env vars (set by the agent harness, never written to
  disk):

    * `ZULIP_SITE`    — e.g. `https://gofish.zulipchat.com`
    * `ZULIP_EMAIL`   — the bot's email
    * `ZULIP_API_KEY` — the bot's API key (Settings → Personal → API key)

  All calls return `{:ok, decoded_body}` on 2xx with a `result: "success"`
  payload, `{:error, reason}` otherwise. We don't try to be clever about
  rate-limiting yet — let `Req` retry on 429s if it's configured to.

  Why a thin client: keeps the MCP tool surface (`ZulipMcp`) free of HTTP
  glue, and lets `EventsLongPollClient` reuse the same auth without
  duplicating env-var reads.
  """

  @doc """
  Search messages by `narrow` spec. The Zulip "narrow" is a list of
  `{operator, operand}` pairs that filter the message stream — see
  https://zulip.com/api/construct-narrow.

  Options (subset matching the third-party MCP tool surface so we can
  swap):

    * `:narrow` — list of `{operator, operand}` tuples (see above)
    * `:anchor` — `"newest"` / `"oldest"` / `"first_unread"` / message_id
    * `:num_before` — int, default 50
    * `:num_after`  — int, default 0
    * `:apply_markdown` — bool, default true

  **Crucially: `anchor=newest` + `num_before=N` returns the N most recent
  messages.** That's what `sort_by=newest` is meant to do in the
  third-party MCP; here it just works because we're not putting a sort
  layer on top of Zulip's natural newest-anchor pagination.
  """
  def get_messages(opts) do
    narrow = Keyword.get(opts, :narrow, [])

    params = %{
      "narrow" => narrow |> Enum.map(fn {op, val} -> %{"operator" => op, "operand" => val} end) |> JSON.encode!(),
      "anchor" => Keyword.get(opts, :anchor, "newest"),
      "num_before" => Keyword.get(opts, :num_before, 50),
      "num_after" => Keyword.get(opts, :num_after, 0),
      "apply_markdown" => Keyword.get(opts, :apply_markdown, true) |> to_string()
    }

    request(:get, "/api/v1/messages", params: params)
  end

  @doc """
  Fetch a single message by id.
  """
  def get_message(message_id, opts \\ []) do
    apply_markdown = Keyword.get(opts, :apply_markdown, true)

    request(:get, "/api/v1/messages/#{message_id}",
      params: %{"apply_markdown" => to_string(apply_markdown)}
    )
  end

  @doc """
  Send a stream or private message. Returns `{:ok, %{"id" => msg_id}}` on
  success.
  """
  def send_message(type, to, topic, content) when type in ["stream", "private"] do
    body = %{
      "type" => type,
      "to" => to_string(to),
      "content" => content
    }

    body = if type == "stream" and topic, do: Map.put(body, "topic", topic), else: body

    request(:post, "/api/v1/messages", form: body)
  end

  @doc """
  Register an event queue. Returns `{:ok, %{"queue_id" => ..., "last_event_id" => ..., ...}}`.

  Event types worth subscribing to:

    * `"message"` — new messages (the main signal)
    * `"reaction"` — emoji reactions
    * `"update_message"` — edits

  Pass a narrow if you only want to be woken on messages matching it.
  """
  def register_event_queue(event_types, narrow \\ nil) do
    body =
      %{
        "event_types" => JSON.encode!(event_types),
        "all_public_streams" => "true"
      }
      |> maybe_add_narrow(narrow)

    request(:post, "/api/v1/register", form: body)
  end

  defp maybe_add_narrow(body, nil), do: body
  defp maybe_add_narrow(body, narrow), do: Map.put(body, "narrow", JSON.encode!(narrow))

  @doc """
  Long-poll for events. Blocks server-side up to ~10s.
  """
  def get_events(queue_id, last_event_id, opts \\ []) do
    dont_block = Keyword.get(opts, :dont_block, false)

    request(:get, "/api/v1/events",
      params: %{
        "queue_id" => queue_id,
        "last_event_id" => to_string(last_event_id),
        "dont_block" => to_string(dont_block)
      },
      receive_timeout: 30_000
    )
  end

  # --- Private ---

  defp request(method, path, opts) do
    {site, email, api_key} = creds()
    url = site <> path

    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)

    req_opts =
      [
        method: method,
        url: url,
        auth: {:basic, "#{email}:#{api_key}"},
        receive_timeout: receive_timeout
      ]
      |> maybe_put(:params, opts[:params])
      |> maybe_put(:form, opts[:form])

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case body do
          %{"result" => "success"} = ok -> {:ok, ok}
          %{"result" => "error", "msg" => msg} -> {:error, {:zulip_error, msg}}
          other -> {:ok, other}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp creds do
    site = System.fetch_env!("ZULIP_SITE") |> String.trim_trailing("/")
    email = System.fetch_env!("ZULIP_EMAIL")
    api_key = System.fetch_env!("ZULIP_API_KEY")
    {site, email, api_key}
  end
end
