defmodule ZulipMcp.AgentRegistry do
  @moduledoc """
  Stable agent profiles + session→topic bindings, persisted to a JSON file.

  This is the functional core behind the `register_agent` and
  `ensure_agent_session` tools (parity with the third-party MCP). It does
  pure state work only — file load/save + deterministic id derivation — and
  performs **no** Zulip API calls. The shell (the tool handlers in `ZulipMcp`)
  owns the side effect of posting the lifecycle message, so this module stays
  trivially testable against a tmp store with no network.

  Identity is deterministic so both tools are idempotent:

    * `agent_id`   = sha256("agent_name|agent_type|owner_email")[0..11]
    * `session_id` = sha256("agent_id|external_session_id|project|topic")[0..15]

  Re-registering the same agent returns the same `agent_id` (upsert);
  re-ensuring the same session returns the same `session_id` and topic
  binding (refresh), matching the reference's "register or update" /
  "create or refresh" semantics.
  """

  @default_stream "agents"
  @default_topic_prefix "Agents/Session"

  @doc "Path to the JSON store. Override in config/test via :agent_store."
  def store_path do
    Application.get_env(
      :zulip_mcp_ex,
      :agent_store,
      Path.join(System.tmp_dir!(), "zulip_mcp_agents.json")
    )
  end

  @doc """
  Register or update a stable agent profile. Returns `{:ok, profile}` where
  `profile` includes the derived `agent_id`. Idempotent on
  agent_name/type/owner.
  """
  def register(opts) when is_map(opts) do
    agent_name = str(opts, "agent_name", "claude")
    agent_type = str(opts, "agent_type", "claude-code")
    owner_email = str(opts, "owner_email", nil)
    stream_name = str(opts, "stream_name", nil)
    topic_prefix = str(opts, "topic_prefix", @default_topic_prefix)
    metadata = Map.get(opts, "metadata") || %{}

    agent_id = derive_agent_id(agent_name, agent_type, owner_email)

    profile = %{
      "agent_id" => agent_id,
      "agent_name" => agent_name,
      "agent_type" => agent_type,
      "owner_email" => owner_email,
      "stream_name" => stream_name,
      "topic_prefix" => topic_prefix,
      "metadata" => metadata,
      "updated_at" => System.system_time(:second)
    }

    store = load()
    save(put_in(store, ["agents", agent_id], profile))
    {:ok, profile}
  end

  @doc """
  Create or refresh a session→topic binding for a previously-registered
  agent. Returns `{:ok, session, change}` where `change` is `:new` the first
  time a session id is seen and `:refreshed` thereafter, OR
  `{:error, :unknown_agent}` if `agent_id` was never registered.

  `change` lets the shell decide whether to post a lifecycle message (we post
  on `:new` or when `status` changed) so refresh calls don't spam the topic.
  """
  def ensure_session(%{"agent_id" => agent_id} = opts) do
    store = load()

    case get_in(store, ["agents", agent_id]) do
      nil ->
        {:error, :unknown_agent}

      profile ->
        external_session_id = str(opts, "external_session_id", nil)
        project_name = str(opts, "project_name", nil)
        project_dir = str(opts, "project_dir", nil)
        status = str(opts, "status", "active")
        explicit_topic = str(opts, "topic_name", nil)
        metadata = Map.get(opts, "metadata") || %{}

        project = project_name || profile["agent_name"]
        session_id = derive_session_id(agent_id, external_session_id, project, explicit_topic)

        topic =
          explicit_topic ||
            "#{profile["topic_prefix"]}/#{profile["agent_name"]}/#{project}/#{String.slice(session_id, 0, 8)}"

        stream = profile["stream_name"] || default_stream()

        prior = get_in(store, ["sessions", session_id])
        change = if prior == nil or prior["status"] != status, do: :new, else: :refreshed

        session = %{
          "session_id" => session_id,
          "agent_id" => agent_id,
          "agent_name" => profile["agent_name"],
          "external_session_id" => external_session_id,
          "project_name" => project_name,
          "project_dir" => project_dir,
          "stream" => stream,
          "topic" => topic,
          "status" => status,
          "metadata" => metadata,
          "updated_at" => System.system_time(:second)
        }

        save(put_in(store, ["sessions", session_id], session))
        {:ok, session, change}
    end
  end

  # --- id derivation ---

  defp derive_agent_id(name, type, owner) do
    hash12("#{name}|#{type}|#{owner}")
  end

  defp derive_session_id(agent_id, external, project, topic) do
    "#{agent_id}|#{external}|#{project}|#{topic}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp hash12(input) do
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  # --- persistence ---

  defp load do
    path = store_path()

    case File.read(path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"agents" => _, "sessions" => _} = store} -> store
          _ -> empty_store()
        end

      {:error, _} ->
        empty_store()
    end
  end

  defp save(store) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(store))
    store
  end

  defp empty_store, do: %{"agents" => %{}, "sessions" => %{}}

  defp default_stream do
    Application.get_env(:zulip_mcp_ex, :agent_default_stream, @default_stream)
  end

  defp str(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      "" -> default
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end
end
