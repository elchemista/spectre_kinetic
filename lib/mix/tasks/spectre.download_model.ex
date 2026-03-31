defmodule Mix.Tasks.Spectre.DownloadModel do
  use Mix.Task

  @moduledoc """
  Installs the upstream example model pack and optional test registry files.

  By default, the task derives the upstream git revision from the native Cargo
  dependency so the downloaded assets stay aligned with the Rust engine version
  this project actually builds against.
  """

  alias SpectreKinetic.Helper

  @shortdoc "Install the upstream model pack locally"

  @switches [
    out: :string,
    pack: :string,
    commit: :string,
    source_dir: :string,
    with_test_registry: :boolean,
    registry_dir: :string,
    force: :boolean
  ]

  @doc """
  Runs the task and installs example model assets locally.
  """
  @spec run([binary()]) :: any()
  @impl true
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = opts[:out] || Mix.raise("missing required option --out")
    pack = opts[:pack] || "minilm"
    commit = opts[:commit] || native_engine_ref!()
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
    if File.exists?(destination) and not force? do
      Mix.shell().info("skip #{destination}")
    else
      File.mkdir_p!(Path.dirname(destination))

      if is_binary(source_path) and File.exists?(source_path) do
        Mix.shell().info("copy #{source_path} -> #{destination}")
        File.cp!(source_path, destination)
      else
        Mix.shell().info("download #{remote_url} -> #{destination}")
        download_with_system!(remote_url, destination)
      end
    end
  end

  defp raw_url(commit, path) do
    "https://raw.githubusercontent.com/elchemista/spectre-kinetic-engine/#{commit}/#{path}"
  end

  defp native_engine_ref! do
    cargo_lock_ref() || cargo_manifest_ref() ||
      Mix.raise("could not determine spectre-kinetic-engine git ref from native Cargo metadata")
  end

  defp cargo_lock_ref do
    lock_path = Path.join(Path.dirname(Helper.native_manifest_path()), "Cargo.lock")

    if File.exists?(lock_path) do
      lock_path
      |> File.read!()
      |> extract_lock_ref()
    end
  end

  defp cargo_manifest_ref do
    Helper.native_manifest_path()
    |> File.read!()
    |> extract_manifest_ref()
  end

  defp extract_lock_ref(contents) do
    case Regex.run(
           ~r/source = "git\+https:\/\/github\.com\/elchemista\/spectre-kinetic-engine\.git(?:\?[^"]*)?#([0-9a-f]{7,40})"/,
           contents,
           capture: :all_but_first
         ) do
      [ref] -> ref
      _ -> nil
    end
  end

  defp extract_manifest_ref(contents) do
    case Regex.run(~r/rev\s*=\s*"([0-9a-f]{7,40})"/, contents, capture: :all_but_first) do
      [ref] -> ref
      _ -> nil
    end
  end

  defp find_local_source do
    [
      System.get_env("SPECTRE_KINETIC_FIXTURES_ROOT"),
      Path.expand("../spectre-kinetic", Helper.app_root()),
      Path.expand("../spectre-kinetic-engine", Helper.app_root())
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
