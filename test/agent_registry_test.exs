defmodule ZulipMcp.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias ZulipMcp.AgentRegistry

  setup do
    # Point the registry at a throwaway store per test so we never touch a
    # shared file (and never hit Zulip — AgentRegistry does no API calls).
    path =
      Path.join(
        System.tmp_dir!(),
        "zulip_mcp_agents_test_#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:zulip_mcp_ex, :agent_store, path)
    on_exit(fn -> File.rm_rf!(path) end)
    :ok
  end

  test "register is idempotent — same identity yields same agent_id" do
    {:ok, a} =
      AgentRegistry.register(%{
        "agent_name" => "armstrong",
        "owner_email" => "curator@gofish.gallery"
      })

    {:ok, b} =
      AgentRegistry.register(%{
        "agent_name" => "armstrong",
        "owner_email" => "curator@gofish.gallery"
      })

    assert a["agent_id"] == b["agent_id"]
    assert String.length(a["agent_id"]) == 12

    {:ok, c} =
      AgentRegistry.register(%{"agent_name" => "phil", "owner_email" => "curator@gofish.gallery"})

    refute c["agent_id"] == a["agent_id"]
  end

  test "ensure_session binds a topic in the team's shape and is idempotent" do
    {:ok, agent} =
      AgentRegistry.register(%{
        "agent_name" => "armstrong",
        "owner_email" => "curator@gofish.gallery",
        "stream_name" => "sandbox",
        "topic_prefix" => "Agents/Session"
      })

    {:ok, s1, c1} =
      AgentRegistry.ensure_session(%{
        "agent_id" => agent["agent_id"],
        "external_session_id" => "abc-123",
        "project_name" => "drabardi"
      })

    assert c1 == :new
    assert s1["stream"] == "sandbox"
    assert s1["topic"] =~ ~r"^Agents/Session/armstrong/drabardi/[0-9a-f]{8}$"

    # Same agent + external session => same session_id + topic, now a refresh.
    {:ok, s2, c2} =
      AgentRegistry.ensure_session(%{
        "agent_id" => agent["agent_id"],
        "external_session_id" => "abc-123",
        "project_name" => "drabardi"
      })

    assert s2["session_id"] == s1["session_id"]
    assert s2["topic"] == s1["topic"]
    assert c2 == :refreshed
  end

  test "status change re-arms the lifecycle signal" do
    {:ok, agent} = AgentRegistry.register(%{"agent_name" => "armstrong"})
    base = %{"agent_id" => agent["agent_id"], "external_session_id" => "s1"}

    {:ok, _s, :new} = AgentRegistry.ensure_session(base)
    {:ok, _s, :refreshed} = AgentRegistry.ensure_session(base)
    {:ok, _s, :new} = AgentRegistry.ensure_session(Map.put(base, "status", "done"))
  end

  test "explicit topic_name overrides the derived topic" do
    {:ok, agent} =
      AgentRegistry.register(%{"agent_name" => "armstrong", "stream_name" => "sandbox"})

    {:ok, s, _} =
      AgentRegistry.ensure_session(%{
        "agent_id" => agent["agent_id"],
        "topic_name" => "Custom/Topic"
      })

    assert s["topic"] == "Custom/Topic"
  end

  test "ensure_session on an unregistered agent is rejected" do
    assert {:error, :unknown_agent} =
             AgentRegistry.ensure_session(%{"agent_id" => "deadbeef0000"})
  end

  test "state persists across calls (survives a reload from disk)" do
    {:ok, agent} = AgentRegistry.register(%{"agent_name" => "armstrong"})

    {:ok, s1, :new} =
      AgentRegistry.ensure_session(%{
        "agent_id" => agent["agent_id"],
        "external_session_id" => "p"
      })

    # A fresh ensure reads the persisted store and recognises the prior session.
    {:ok, s2, :refreshed} =
      AgentRegistry.ensure_session(%{
        "agent_id" => agent["agent_id"],
        "external_session_id" => "p"
      })

    assert s1["session_id"] == s2["session_id"]
  end
end
