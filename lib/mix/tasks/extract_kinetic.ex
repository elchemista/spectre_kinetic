defmodule Mix.Tasks.ExtractKinetic do
  use Mix.Task

  alias SpectreKinetic.Planner.Compiler
  alias SpectreKinetic.Tool.Extractor

  @moduledoc """
  Extracts planner-visible tools from compiled Elixir modules and writes kinetic registry artifacts.

  ## Usage

      mix extract_kinetic --app my_app --out registry.json
      mix extract_kinetic --app my_app --encoder artifacts/encoder --out artifacts/registry/registry.etf
  """

  @shortdoc "Extract planner-visible tools from compiled modules"

  @switches [
    app: :string,
    out: :string,
    encoder: :string,
    batch_size: :integer
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("compile")
    Mix.Task.run("app.start")

    {opts, out} = parse_opts!(argv)
    actions = extract_actions!(opts[:app] || default_app())
    write_output!(out, actions, opts)
    Mix.shell().info("Extracted #{length(actions)} tools to #{out}")
  end

  defp default_app do
    Mix.Project.config()[:app]
    |> to_string()
  end

  defp write_json(path, actions) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"actions" => actions}, pretty: true))
  end

  defp parse_opts!(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")
    {opts, opts[:out] || Mix.raise("missing required option --out")}
  end

  defp extract_actions!(app) do
    app_atom = String.to_atom(app)
    _ = Application.load(app_atom)

    case Extractor.extract_app(app_atom) do
      {:ok, actions} -> actions
      {:error, reason} -> Mix.raise("tool extraction failed: #{inspect(reason)}")
    end
  end

  defp write_output!(out, actions, opts) do
    case Path.extname(out) do
      ".json" -> write_json(out, actions)
      ".etf" -> compile_output!(out, actions, opts)
      other -> Mix.raise("unsupported output format #{inspect(other)}. Use .json or .etf")
    end
  end

  defp compile_output!(out, actions, opts) do
    encoder = opts[:encoder] || Mix.raise("missing required option --encoder for ETF output")

    case Compiler.compile(
           actions: actions,
           encoder_model_dir: encoder,
           output: out,
           batch_size: opts[:batch_size] || 32
         ) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("tool extraction failed: #{inspect(reason)}")
    end
  end
end
