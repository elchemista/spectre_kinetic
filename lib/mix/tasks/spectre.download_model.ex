defmodule Mix.Tasks.Spectre.DownloadModel do
  use Mix.Task

  alias SpectreKinetic.Runtime

  @shortdoc "Install the pinned upstream model pack locally"

  @switches [
    out: :string,
    pack: :string,
    commit: :string,
    source_dir: :string,
    with_test_registry: :boolean,
    registry_dir: :string,
    force: :boolean
  ]

  @impl true
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = opts[:out] || Mix.raise("missing required option --out")
    pack = opts[:pack] || "minilm"
    commit = opts[:commit] || Runtime.engine_commit()
    source_dir = opts[:source_dir] || find_local_source()
    force? = opts[:force] || false

    install_pack!(commit, pack, out_dir, source_dir, force?)

    if opts[:with_test_registry] do
      registry_dir = opts[:registry_dir] || Path.join(Path.dirname(out_dir), "registry")
      install_registry!(commit, registry_dir, source_dir, force?)
    end
  end

  defp install_pack!(commit, pack, out_dir, source_dir, force?) do
    Enum.each(["pack.json", "tokenizer.json", "token_embeddings.bin", "weights.json"], fn file ->
      source_path = source_dir && Path.join([source_dir, "packs", pack, file])
      remote_url = raw_url(commit, "packs/#{pack}/#{file}")
      destination = Path.join(out_dir, file)
      fetch_asset!(source_path, remote_url, destination, force?)
    end)
  end

  defp install_registry!(commit, out_dir, source_dir, force?) do
    Enum.each(
      [
        {"tests/test_registry.json", "test_registry.json"},
        {"tests/test_registry.mcr", "test_registry.mcr"}
      ],
      fn {remote_path, local_name} ->
        source_path = source_dir && Path.join(source_dir, remote_path)
        remote_url = raw_url(commit, remote_path)
        destination = Path.join(out_dir, local_name)
        fetch_asset!(source_path, remote_url, destination, force?)
      end
    )
  end

  defp fetch_asset!(source_path, remote_url, destination, force?) do
    cond do
      File.exists?(destination) and not force? ->
        Mix.shell().info("skip #{destination}")

      true ->
        File.mkdir_p!(Path.dirname(destination))

        cond do
          is_binary(source_path) and File.exists?(source_path) ->
            Mix.shell().info("copy #{source_path} -> #{destination}")
            File.cp!(source_path, destination)

          true ->
            Mix.shell().info("download #{remote_url} -> #{destination}")
            download_with_system!(remote_url, destination)
        end
    end
  end

  defp raw_url(commit, path) do
    "https://raw.githubusercontent.com/elchemista/spectre-kinetic-engine/#{commit}/#{path}"
  end

  defp find_local_source do
    [
      System.get_env("SPECTRE_KINETIC_FIXTURES_ROOT"),
      Path.expand("../spectre-kinetic", Runtime.app_root()),
      Path.expand("../spectre-kinetic-engine", Runtime.app_root())
    ]
    |> Enum.find(&valid_source?/1)
  end

  defp valid_source?(nil), do: false

  defp valid_source?(path) do
    File.dir?(path) and
      (File.exists?(Path.join(path, "packs/minilm/pack.json")) or
         File.exists?(Path.join(path, "tests/test_registry.json")))
  end

  defp download_with_system!(url, destination) do
    cond do
      curl = System.find_executable("curl") ->
        {_output, status} =
          System.cmd(curl, ["-fsSL", url, "-o", destination], stderr_to_stdout: true)

        status == 0 || Mix.raise("curl download failed for #{url}")

      wget = System.find_executable("wget") ->
        {_output, status} =
          System.cmd(wget, ["-q", "-O", destination, url], stderr_to_stdout: true)

        status == 0 || Mix.raise("wget download failed for #{url}")

      true ->
        Mix.raise("need either `curl` or `wget` to fetch model assets")
    end
  end
end
