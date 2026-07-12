defmodule Mix.Tasks.CompileKinetic do
  use Mix.Task

  @moduledoc false
  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    Mix.shell().info("mix compile_kinetic is deprecated; use mix spectre_kinetic.compile")
    Mix.Task.run("spectre_kinetic.compile", argv)
  end
end
