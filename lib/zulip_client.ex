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
      "narrow" =>
        narrow
        |> Enum.map(fn {op, val} -> %{"operator" => op, "operand" => val} end)
        |> JSON.encode!(),
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

  @doc """
  Edit a message. Pass `topic` for stream messages if you want to move
  the message between topics. `propagate_mode` is one of "change_one"
  (default), "change_later", "change_all".
  """
  def update_message(message_id, opts) do
    body =
      %{}
      |> maybe_put_form("content", opts[:content])
      |> maybe_put_form("topic", opts[:topic])
      |> maybe_put_form("propagate_mode", opts[:propagate_mode])

    request(:patch, "/api/v1/messages/#{message_id}", form: body)
  end

  @doc """
  Add an emoji reaction. `emoji_name` is the Zulip name (no colons),
  e.g. `"tropical_fish"`.
  """
  def add_reaction(message_id, emoji_name) do
    request(:post, "/api/v1/messages/#{message_id}/reactions",
      form: %{"emoji_name" => emoji_name}
    )
  end

  @doc """
  Remove an emoji reaction.
  """
  def remove_reaction(message_id, emoji_name) do
    request(:delete, "/api/v1/messages/#{message_id}/reactions",
      params: %{"emoji_name" => emoji_name}
    )
  end

  @doc """
  Upload a file from disk to Zulip's user_uploads endpoint. Returns
  `{:ok, %{"uri" => "/user_uploads/...", "url" => "/user_uploads/..."}}`.

  The returned `uri` can be embedded in a message as `[filename](uri)`
  so the client renders the attachment inline.
  """
  def upload_file(path) do
    filename = Path.basename(path)
    body = File.read!(path)
    content_type = mime_type(filename)

    {site, email, api_key} = creds()
    url = site <> "/api/v1/user_uploads"

    case Req.request(
           method: :post,
           url: url,
           auth: {:basic, "#{email}:#{api_key}"},
           form_multipart: [
             {"file", {body, filename: filename, content_type: content_type}}
           ],
           receive_timeout: 60_000
         ) do
      {:ok, %Req.Response{status: status, body: %{"result" => "success"} = ok}}
      when status in 200..299 ->
        {:ok, ok}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @doc """
  List streams the bot can see. `include_public` defaults to true.
  """
  def get_streams(opts \\ []) do
    request(:get, "/api/v1/streams",
      params: %{
        "include_public" => Keyword.get(opts, :include_public, true) |> to_string(),
        "include_subscribed" => Keyword.get(opts, :include_subscribed, true) |> to_string()
      }
    )
  end

  @doc """
  Recent topics in a stream, newest-first (Zulip returns them ordered by
  max_id descending). GET /api/v1/users/me/{stream_id}/topics.
  """
  def get_stream_topics(stream_id) do
    request(:get, "/api/v1/users/me/#{stream_id}/topics", params: %{})
  end

  @doc """
  Get the user list. By default returns active users only.
  """
  def get_users(opts \\ []) do
    request(:get, "/api/v1/users",
      params: %{
        "client_gravatar" => Keyword.get(opts, :client_gravatar, false) |> to_string(),
        "include_custom_profile_fields" =>
          Keyword.get(opts, :include_custom_profile_fields, false) |> to_string()
      }
    )
  end

  # --- Topic subscriptions / followed topics (GOF-73) ---
  # Zulip models "subscribe to a topic" as a user_topic visibility_policy.
  # Values: 0 = inherit/none, 1 = muted, 2 = unmuted, 3 = followed.
  # NB: exact request/response shapes verified against Zulip's REST API docs;
  # Boblak's QA pass confirms live behaviour end-to-end.

  @visibility_followed 3
  @visibility_none 0

  @doc """
  Set a (stream_id, topic) visibility policy via POST /api/v1/user_topics.
  Idempotent server-side. `policy` is one of the visibility_policy ints above.
  """
  def set_topic_visibility(stream_id, topic, policy)
      when is_integer(stream_id) and is_binary(topic) and is_integer(policy) do
    request(:post, "/api/v1/user_topics",
      form: %{
        "stream_id" => stream_id,
        "topic" => topic,
        "visibility_policy" => policy
      }
    )
  end

  @doc "Follow a topic (visibility_policy = followed)."
  def follow_topic(stream_id, topic), do: set_topic_visibility(stream_id, topic, @visibility_followed)

  @doc "Stop following a topic (visibility_policy = inherit/none)."
  def unfollow_topic(stream_id, topic), do: set_topic_visibility(stream_id, topic, @visibility_none)

  @doc """
  Fetch the bot's user_topics state. Zulip has no dedicated GET list endpoint —
  the followed set lives in the `/register` snapshot — so we request only the
  user_topic state (no long-lived event queue). Returns the raw `user_topics`
  list; the caller filters by visibility_policy (3 = followed).
  """
  def get_user_topics do
    request(:post, "/api/v1/register",
      form: %{"fetch_event_types" => JSON.encode!(["user_topic"])}
    )
  end

  @doc """
  Mark messages read by id via POST /api/v1/messages/flags (op=add, flag=read).
  Explicit cursor-advance for catch_up — only clears what the caller actually
  processed, so a partial batch never silently drops the rest.
  """
  def mark_messages_read(message_ids) when is_list(message_ids) do
    request(:post, "/api/v1/messages/flags",
      form: %{
        "messages" => JSON.encode!(message_ids),
        "op" => "add",
        "flag" => "read"
      }
    )
  end

  defp maybe_put_form(form, _key, nil), do: form
  defp maybe_put_form(form, key, value), do: Map.put(form, key, to_string(value))

  defp mime_type(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".pdf" -> "application/pdf"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      _ -> "application/octet-stream"
    end
  end

  # --- Private ---

  # Extra attempts on a read timeout, each widening the receive budget. The
  # global is_mentioned narrow in particular routinely needs more than the 15s
  # default — returning empty/error on the first timeout is what made agents
  # silently miss mentions (Guppie msg 597326240).
  @timeout_retries 2

  defp request(method, path, opts) do
    {site, email, api_key} = creds()
    url = site <> path
    base_timeout = Keyword.get(opts, :receive_timeout, 15_000)

    build = fn timeout ->
      [
        method: method,
        url: url,
        auth: {:basic, "#{email}:#{api_key}"},
        receive_timeout: timeout
      ]
      |> maybe_put(:params, opts[:params])
      |> maybe_put(:form, opts[:form])
      |> maybe_put_method_body(method, opts[:form])
    end

    run_with_timeout_retry(build, base_timeout, method, 0)
  end

  defp run_with_timeout_retry(build, timeout, method, attempt) do
    case Req.request(build.(timeout)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case body do
          %{"result" => "success"} = ok -> {:ok, ok}
          %{"result" => "error", "msg" => msg} -> {:error, {:zulip_error, msg}}
          other -> {:ok, other}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      # Retry timeouts ONLY for GETs (idempotent). Retrying a write that may
      # have already landed server-side risks a double-post, so we never do it.
      {:error, %{reason: :timeout}} when method == :get and attempt < @timeout_retries ->
        run_with_timeout_retry(build, round(timeout * 1.5), method, attempt + 1)

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # PATCH/DELETE with body sometimes need form data routed differently
  # in Req; this is a passthrough placeholder for future tuning.
  defp maybe_put_method_body(opts, _method, _form), do: opts

  defp creds do
    site = System.fetch_env!("ZULIP_SITE") |> String.trim_trailing("/")
    email = System.fetch_env!("ZULIP_EMAIL")
    api_key = System.fetch_env!("ZULIP_API_KEY")
    {site, email, api_key}
  end
end
