defmodule Mix.Tasks.Spectre.Show do
  use Mix.Task

  @moduledoc """
  Shows runtime information for a model/registry pair and optionally plans
  either one AL instruction or a whole LLM response.
  """

  alias SpectreKinetic.Runtime

  @shortdoc "Inspect a model/registry pair and optionally resolve an AL statement"

  @switches [
    model: :string,
    registry: :string,
    al: :string,
    text: :string,
    file: :string,
    top_k: :integer,
    tool_threshold: :float,
    mapping_threshold: :float,
    slot: :keep,
    format: :string
  ]

  @doc """
  Runs the task and prints either runtime summary information or planning output.
  """
  @spec run([binary()]) :: any()
  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    runtime_opts =
      opts
      |> Keyword.take([:model, :registry])
      |> Enum.map(fn
        {:model, value} -> {:model_dir, value}
        {:registry, value} -> {:registry_mcr, value}
      end)

    resolved_paths = Runtime.resolve_runtime_paths!(runtime_opts)

    {:ok, pid} = SpectreKinetic.start_link(runtime_opts ++ [name: nil])

    summary = %{
      version: SpectreKinetic.version(),
      action_count: SpectreKinetic.action_count(pid),
      model_dir: resolved_paths.model_dir,
      registry_mcr: resolved_paths.registry_mcr
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

  defp render(payload, "json") do
    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  defp render(payload, _pretty) do
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
