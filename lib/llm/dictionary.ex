defmodule SpectreKinetic.Dictionary do
  @moduledoc """
  Builds compact AL dictionaries from a registry JSON file.

  This is intended for prompt minimization: you can scope the dictionary to only
  the action ids relevant to the current turn.
  """

  @derive {Jason.Encoder, only: [:action_ids, :keywords, :slots, :examples]}

  alias SpectreKinetic.Planner.Registry.ETS

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
  @default_example_limit 20
  @max_dictionary_items 1_000

  @doc """
  Builds a scoped dictionary from the configured registry JSON file.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts \\ []) do
    with :ok <- SpectreKinetic.RuntimeConfig.validate_options(opts),
         {:ok, path} <- registry_json_path(opts),
         {:ok, action_scope} <- action_scope(opts),
         {:ok, top_n} <- bounded_count(opts, :top_n, @default_top_n),
         {:ok, example_limit} <-
           bounded_count(opts, :example_limit, @default_example_limit),
         {:ok, actions} <- load_actions(path) do
      actions = filter_actions(actions, action_scope)

      {:ok,
       %__MODULE__{
         action_ids: Enum.map(actions, & &1["id"]),
         keywords: collect_keywords(actions, top_n),
         slots: collect_slots(actions),
         examples: collect_examples(actions, example_limit)
       }}
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Builds a scoped dictionary and raises on failure.
  """
  @spec build!(keyword()) :: t()
  def build!(opts \\ []) do
    case build(opts) do
      {:ok, dictionary} -> dictionary
      {:error, reason} -> raise ArgumentError, "failed to build dictionary: #{inspect(reason)}"
    end
  end

  @doc """
  Builds compact prompt text from the scoped dictionary.
  """
  @spec text(keyword()) :: {:ok, binary()} | {:error, term()}
  def text(opts \\ []) do
    with {:ok, dictionary} <- build(opts) do
      {:ok, to_text(dictionary)}
    end
  end

  @doc """
  Builds compact prompt text and raises on failure.
  """
  @spec text!(keyword()) :: binary()
  def text!(opts \\ []) do
    opts |> build!() |> to_text()
  end

  @doc """
  Renders the dictionary as compact multi-line prompt text.
  """
  @spec to_text(t()) :: binary()
  def to_text(%__MODULE__{} = dictionary) do
    [
      Enum.join(dictionary.keywords, " "),
      Enum.join(dictionary.slots, " "),
      Enum.join(dictionary.examples, " | ")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp registry_json_path(opts) do
    SpectreKinetic.RuntimeConfig.resolve_required_path(
      opts,
      :registry_json,
      :registry_json,
      "SPECTRE_KINETIC_REGISTRY_JSON"
    )
  end

  defp load_actions(path) do
    case ETS.new(registry_json: path) do
      {:ok, registry} ->
        try do
          {:ok, ETS.all_actions(registry)}
        after
          ETS.close(registry)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp action_scope(opts) do
    case Keyword.get(opts, :actions) do
      nil ->
        {:ok, nil}

      ids when is_list(ids) ->
        if valid_action_scope?(ids, @max_dictionary_items),
          do: {:ok, ids},
          else: {:error, {:invalid_option, :actions}}

      _invalid ->
        {:error, {:invalid_option, :actions}}
    end
  end

  defp valid_action_scope?([], _remaining), do: true
  defp valid_action_scope?([_id | _tail], 0), do: false

  defp valid_action_scope?([id | tail], remaining) when is_binary(id),
    do: valid_action_scope?(tail, remaining - 1)

  defp valid_action_scope?(_invalid, _remaining), do: false

  defp bounded_count(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 and value <= @max_dictionary_items ->
        {:ok, value}

      _invalid ->
        {:error, {:invalid_option, key}}
    end
  end

  defp filter_actions(actions, nil), do: actions

  defp filter_actions(actions, ids) when is_list(ids) do
    wanted = MapSet.new(ids)
    Enum.filter(actions, &MapSet.member?(wanted, &1["id"]))
  end

  defp collect_keywords(actions, top_n) do
    actions
    |> Enum.flat_map(&action_tokens/1)
    |> Enum.map(&String.upcase/1)
    |> Enum.filter(&(String.length(&1) >= 2 and String.match?(&1, ~r/[A-Z]/)))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {word, count} -> {-count, word} end)
    |> Enum.take(top_n)
    |> Enum.map(&elem(&1, 0))
  end

  defp collect_slots(actions) do
    actions
    |> Enum.flat_map(&action_slots/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_tokens(action) do
    action
    |> action_text_sources()
    |> Enum.flat_map(&split_tokens/1)
  end

  defp action_text_sources(action) do
    examples = action["examples"] || []
    [action["module"], action["name"], action["doc"], action["spec"] | examples]
  end

  defp action_slots(action) do
    action
    |> Map.get("args", [])
    |> Enum.flat_map(&arg_slots/1)
  end

  defp arg_slots(arg) do
    aliases = arg["aliases"] || []

    [arg["name"] | aliases]
    |> Enum.map(&String.downcase(&1 || ""))
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
end
