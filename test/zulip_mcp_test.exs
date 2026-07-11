defmodule ZulipMcpTest do
  use ExUnit.Case
  doctest ZulipMcp

  test "tools/0 advertises the agent-lifecycle tools" do
    names = ZulipMcp.tools() |> Enum.map(& &1["name"])
    assert "register_agent" in names
    assert "ensure_agent_session" in names
    # every tool must carry an inputSchema object
    assert Enum.all?(ZulipMcp.tools(), &match?(%{"inputSchema" => %{"type" => "object"}}, &1))
  end

  test "get_streams advertises include_topics + name_contains (the topic-discovery path)" do
    schema =
      ZulipMcp.tools()
      |> Enum.find(&(&1["name"] == "get_streams"))
      |> get_in(["inputSchema", "properties"])

    assert %{"type" => "boolean"} = schema["include_topics"]
    assert %{"type" => "string"} = schema["name_contains"]
  end

  test "unknown tool returns a clear error" do
    assert {:error, "Unknown tool: nope"} = ZulipMcp.handle_tool_call("nope", %{})
  end
end
