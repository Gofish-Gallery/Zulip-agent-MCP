defmodule ZulipMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :zulip_mcp_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: ZulipMcp.CLI, app: nil],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"}
    ]
  end
end
