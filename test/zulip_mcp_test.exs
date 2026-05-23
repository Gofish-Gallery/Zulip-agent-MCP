defmodule ZulipMcpTest do
  use ExUnit.Case
  doctest ZulipMcp

  test "greets the world" do
    assert ZulipMcp.hello() == :world
  end
end
