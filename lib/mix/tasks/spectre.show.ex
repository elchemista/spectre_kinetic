defmodule Mix.Tasks.Spectre.Show do
  use Mix.Task

  @moduledoc false
  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    Mix.shell().info("mix spectre.show is deprecated; use mix spectre_kinetic.show")
    Mix.Task.run("spectre_kinetic.show", argv)
  end
end
