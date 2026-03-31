defmodule SpectreKinetic.Dictionary do
  @moduledoc """
  Builds compact AL dictionaries from a registry JSON file.

  This is intended for prompt minimization: you can scope the dictionary to only
  the action ids relevant to the current turn.
  """

  @derive {Jason.Encoder, only: [:action_ids, :keywords, :slots, :examples]}

  defstruct action_ids: [],
            keywords: [],
            slots: [],
            examples: []

  @type t :: %__MODULE__{
          action_ids: [binary()],
          keywords: [binary()],
          slots: [binary()],
          examples: [binary()]
        }

  @default_top_n 200

  def build(opts \\ []) do
    with {:ok, path} <- registry_json_path(opts),
         {:ok, payload} <- File.read(path),
         {:ok, registry} <- Jason.decode(payload) do
      actions =
        registry
        |> Map.get("actions", Map.get(registry, "tools", []))
        |> filter_actions(opts[:actions])

      {:ok,
       %__MODULE__{
         action_ids: Enum.map(actions, & &1["id"]),
         keywords: collect_keywords(actions, Keyword.get(opts, :top_n, @default_top_n)),
         slots: collect_slots(actions),
         examples: collect_examples(actions, Keyword.get(opts, :example_limit, 20))
       }}
    else
      {:error, _} = error -> error
    end
  end

  def build!(opts \\ []) do
    with {:ok, dictionary} <- build(opts) do
      dictionary
    else
      {:error, reason} -> raise ArgumentError, "failed to build dictionary: #{inspect(reason)}"
    end
  end

  def text(opts \\ []), do: with({:ok, dictionary} <- build(opts), do: {:ok, to_text(dictionary)})

  def text!(opts \\ []) do
    opts |> build!() |> to_text()
  end

  def to_text(%__MODULE__{} = dictionary) do
    [
      Enum.join(dictionary.keywords, " "),
      Enum.join(dictionary.slots, " "),
      Enum.join(dictionary.examples, " | ")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp registry_json_path(opts),
    do:
      SpectreKinetic.Runtime.resolve_optional_path(
        opts,
        :registry_json,
        :registry_json,
        "SPECTRE_KINETIC_REGISTRY_JSON"
      )
      |> wrap_registry_json_path()

  defp filter_actions(actions, nil), do: actions

  defp filter_actions(actions, ids) when is_list(ids) do
    wanted = MapSet.new(ids)
    Enum.filter(actions, &MapSet.member?(wanted, &1["id"]))
  end

  defp collect_keywords(actions, top_n) do
    actions
    |> Enum.flat_map(fn action ->
      texts =
        [action["module"], action["name"], action["doc"], action["spec"]]
        |> Kernel.++(action["examples"] || [])

      Enum.flat_map(texts, &split_tokens/1)
    end)
    |> Enum.map(&String.upcase/1)
    |> Enum.filter(&(String.length(&1) >= 2 and String.match?(&1, ~r/[A-Z]/)))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {word, count} -> {-count, word} end)
    |> Enum.take(top_n)
    |> Enum.map(&elem(&1, 0))
  end

  defp collect_slots(actions) do
    actions
    |> Enum.flat_map(fn action ->
      Enum.flat_map(action["args"] || [], fn arg ->
        [String.downcase(arg["name"] || "")]
        |> Kernel.++(Enum.map(arg["aliases"] || [], &String.downcase/1))
      end)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect_examples(actions, limit) do
    actions
    |> Enum.flat_map(&(&1["examples"] || []))
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  defp split_tokens(nil), do: []

  defp split_tokens(text) do
    Regex.scan(~r/[A-Za-z0-9_-]+/, text)
    |> List.flatten()
  end

  defp wrap_registry_json_path(nil), do: {:error, :missing_registry_json}
  defp wrap_registry_json_path(path), do: {:ok, path}
end
