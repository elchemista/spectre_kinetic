defmodule Mix.Tasks.ExtractKinetic do
  use Mix.Task

  @moduledoc false
  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    Mix.shell().info("mix extract_kinetic is deprecated; use mix spectre_kinetic.extract")
    Mix.Task.run("spectre_kinetic.extract", argv)
  end
end
