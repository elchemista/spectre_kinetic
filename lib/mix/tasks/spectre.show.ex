defmodule Mix.Tasks.Spectre.Show do
  use Mix.Task

  @moduledoc """
  Shows runtime information for the Elixir planner artifacts and can optionally
  resolve one AL instruction or response chain.
  """

  alias SpectreKinetic.Runtime

  @shortdoc "Inspect planner artifacts and optionally resolve an AL statement"

  @switches [
    encoder: :string,
    compiled_registry: :string,
    registry_json: :string,
    fallback_model: :string,
    al: :string,
    text: :string,
    file: :string,
    top_k: :integer,
    tool_threshold: :float,
    mapping_threshold: :float,
    slot: :keep,
    format: :string
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    runtime_opts =
      []
      |> maybe_put(:encoder_model_dir, opts[:encoder])
      |> maybe_put(:compiled_registry, opts[:compiled_registry])
      |> maybe_put(:registry_json, opts[:registry_json])
      |> maybe_put(:fallback_model_dir, opts[:fallback_model])

    {:ok, pid} = SpectreKinetic.start_link(runtime_opts ++ [name: nil])
    {:ok, resolved_paths} = Runtime.resolve_runtime_paths(runtime_opts)

    summary = %{
      version: SpectreKinetic.version(),
      action_count: SpectreKinetic.action_count(pid),
      encoder_model_dir: resolved_paths.encoder_model_dir,
      compiled_registry: resolved_paths.compiled_registry,
      registry_json: resolved_paths.registry_json,
      fallback_model_dir: resolved_paths.fallback_model_dir
    }

    case input(opts) do
      nil ->
        render(summary, opts[:format] || "pretty")

      input_text ->
        plan_opts =
          []
          |> maybe_put(:top_k, opts[:top_k])
          |> maybe_put(:tool_threshold, opts[:tool_threshold])
          |> maybe_put(:mapping_threshold, opts[:mapping_threshold])
          |> maybe_put(:slots, parse_slots(opts[:slot] || []))

        payload = build_payload(pid, input_text, plan_opts, summary, opts)
        render(payload, opts[:format] || "pretty")
    end
  end

  defp parse_slots([]), do: %{}

  defp parse_slots(entries) do
    Map.new(entries, fn entry ->
      case String.split(entry, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  defp render(payload, _format) do
    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  defp input(opts) do
    opts
    |> Keyword.get(:file)
    |> read_file_input()
    |> fallback_input(Keyword.get(opts, :text))
    |> fallback_input(Keyword.get(opts, :al))
  end

  defp build_payload(pid, input_text, plan_opts, summary, opts) do
    case Keyword.fetch(opts, :al) do
      {:ok, _al} ->
        {:ok, action} = SpectreKinetic.plan(pid, input_text, plan_opts)
        %{summary: summary, al: input_text, action: action}

      :error ->
        {:ok, chain} = SpectreKinetic.plan_chain(pid, input_text, plan_opts)
        %{summary: summary, chain: chain}
    end
  end

  defp read_file_input(nil), do: nil
  defp read_file_input(path), do: File.read!(path)

  defp fallback_input(nil, fallback), do: fallback
  defp fallback_input(value, _fallback), do: value

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, %{} = value) when map_size(value) == 0, do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
