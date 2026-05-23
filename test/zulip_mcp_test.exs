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

  test "unknown tool returns a clear error" do
    assert {:error, "Unknown tool: nope"} = ZulipMcp.handle_tool_call("nope", %{})
  end
end
