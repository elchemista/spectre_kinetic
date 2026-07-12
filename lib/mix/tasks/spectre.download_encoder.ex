defmodule Mix.Tasks.Spectre.DownloadEncoder do
  use Mix.Task

  @moduledoc false
  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    Mix.shell().info(
      "mix spectre.download_encoder is deprecated; use mix spectre_kinetic.download_encoder"
    )

    Mix.Task.run("spectre_kinetic.download_encoder", argv)
  end
end
