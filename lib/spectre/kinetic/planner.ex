defmodule Spectre.Kinetic.Planner do
  @moduledoc """
  Adapter from the Spectre action-planner port to `SpectreKinetic`.

  Registry extraction, runtime ownership, AL parsing, and selected-tool
  translation live here so the Spectre core remains planner-agnostic.
  """

  alias Spectre.Kinetic.Catalog
  alias SpectreKinetic.Action, as: KineticAction
  alias SpectreKinetic.ActionChain

  @runtime_option_keys [
    :encoder_model_dir,
    :compiled_registry,
    :registry_json,
    :registry_module,
    :allow_empty_registry,
    :embedding_module,
    :embedder,
    :tool_threshold,
    :mapping_threshold,
    :top_k,
    :tool_selection_fallback,
    :fallback_model_dir,
    :fallback_runtime_module,
    :fallback_top_k,
    :fallback_margin,
    :reranker_threshold,
    :reranker,
    :reranker_max_length,
    :reranker_score_index,
    :reranker_score_transform,
    :classifiers
  ]

  @plan_option_keys [
    :slots,
    :top_k,
    :tool_threshold,
    :mapping_threshold,
    :tool_selection_fallback,
    :fallback_top_k,
    :fallback_margin,
    :reranker_threshold,
    :classifiers
  ]

  @temp_registry_attempts 5

  @spec plan_response(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan_response(text, _ctx, opts) when is_binary(text) and is_list(opts) do
    scan = SpectreKinetic.extract_al_scan(text)

    if scan.entries == [] do
      {:ok, %{reply_text: scan.clean_text, actions: []}}
    else
      with {:ok, catalog} <- Catalog.build(opts) do
        with_runtime(
          catalog,
          opts,
          &plan_response_with_runtime(&1, text, scan.clean_text, catalog, opts)
        )
      end
    end
  end

  @spec plan_response_with_runtime(
          term(),
          String.t(),
          String.t(),
          Catalog.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  defp plan_response_with_runtime(runtime, text, clean_text, catalog, opts) do
    with {:ok, chain} <- SpectreKinetic.plan_chain(runtime, text, plan_opts(opts)),
         {:ok, actions} <- convert_chain(chain, catalog) do
      {:ok, %{reply_text: clean_text, actions: actions}}
    end
  end

  @spec plan(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(al, _ctx, opts) when is_binary(al) and is_list(opts) do
    with {:ok, catalog} <- Catalog.build(opts) do
      with_runtime(catalog, opts, &plan_with_runtime(&1, al, catalog, opts))
    end
  end

  @spec plan_with_runtime(term(), String.t(), Catalog.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp plan_with_runtime(runtime, al, catalog, opts) do
    with {:ok, action} <- SpectreKinetic.plan(runtime, al, plan_opts(opts)) do
      convert_action(action, catalog, 0)
    end
  end

  @spec clean_reply(String.t(), map(), keyword()) :: String.t()
  def clean_reply(text, _ctx, _opts) when is_binary(text) do
    text
    |> SpectreKinetic.extract_al_scan()
    |> Map.fetch!(:clean_text)
  end

  @doc """
  Declares that reply cleaning is not safe to apply to individual stream deltas.

  An AL block is only recognizable once its complete text is available, so a
  partial delta cannot be certified as free of Action Language. Streaming
  therefore fails closed for Agents that mount this planner.
  """
  @spec incremental_cleaner?() :: boolean()
  def incremental_cleaner?, do: false

  @spec convert_chain(ActionChain.t(), Catalog.t()) :: {:ok, [map()]} | {:error, term()}
  defp convert_chain(%ActionChain{actions: actions}, catalog) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, converted} ->
      case convert_action(action, catalog, index) do
        {:ok, next} -> {:cont, {:ok, [next | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      {:error, _reason} = error -> error
    end
  end

  @spec convert_action(term(), Catalog.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp convert_action(action, catalog, index) when is_map(action) do
    status = value(action, :status)
    args = value(action, :args)
    al = value(action, :al)

    selected_tool =
      Catalog.exact_tool(catalog, al) ||
        value(action, :selected_tool)

    cond do
      value(action, :halted?) == true ->
        {:error, {:action_plan_halted, index, status}}

      status not in [:ok, "ok"] ->
        {:error, {:action_plan_not_executable, index, status}}

      not is_binary(selected_tool) or String.trim(selected_tool) == "" ->
        {:error, {:action_plan_missing_tool, index}}

      not is_map(args) ->
        {:error, {:invalid_action_args, index, args}}

      true ->
        with {:ok, target} <- Catalog.resolve(catalog, selected_tool) do
          {:ok,
           spectre_action(%{
             name: target.name,
             via: target.via,
             args: args,
             mode: target.mode,
             planned_by: __MODULE__,
             schema_hash: target.schema_hash,
             metadata: %{
               source: :planner,
               al: al,
               selected_tool: selected_tool,
               kinetic: kinetic_metadata(action)
             }
           })}
        end
    end
  end

  defp convert_action(action, _catalog, index),
    do: {:error, {:invalid_planned_action, index, action}}

  @spec spectre_action(map()) :: map()
  defp spectre_action(attrs) do
    action_module = Module.concat(["Spectre", "Action"])

    if Code.ensure_loaded?(action_module) and function_exported?(action_module, :new, 1),
      do: action_module.new(attrs),
      else: attrs
  end

  @spec kinetic_metadata(map()) :: map()
  defp kinetic_metadata(action) do
    action
    |> plain_map()
    |> Map.take([
      :status,
      :confidence,
      :tool_score,
      :mapping_score,
      :combined_score,
      :invalid,
      :missing,
      :notes,
      :classifier_results,
      :warnings,
      :alternatives
    ])
  end

  @spec with_runtime(Catalog.t(), keyword(), (term() -> term())) :: term()
  defp with_runtime(%Catalog{} = catalog, opts, function) do
    case borrowed_runtime(opts) do
      nil -> with_owned_runtime(catalog, opts, function)
      runtime -> with_verified_runtime(runtime, catalog, opts, function)
    end
  end

  @spec borrowed_runtime(keyword()) :: term() | nil
  defp borrowed_runtime(opts) do
    Keyword.get(opts, :runtime) ||
      Application.get_env(:spectre_kinetic, :runtime)
  end

  @spec with_owned_runtime(Catalog.t(), keyword(), (term() -> term())) :: term()
  defp with_owned_runtime(%Catalog{} = catalog, opts, function) do
    runtime_opts = Keyword.take(opts, @runtime_option_keys)
    verified = &with_verified_runtime(&1, catalog, opts, function)

    if configured_registry?(runtime_opts) or catalog.actions == [] do
      load_and_run(runtime_opts, verified)
    else
      with_temp_registry(catalog.actions, runtime_opts, verified)
    end
  end

  @spec load_and_run(keyword(), (term() -> term())) :: term()
  defp load_and_run(runtime_opts, function) do
    case SpectreKinetic.load_runtime(runtime_opts) do
      {:ok, runtime} ->
        try do
          function.(runtime)
        after
          SpectreKinetic.close_runtime(runtime)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec with_verified_runtime(term(), Catalog.t(), keyword(), (term() -> term())) :: term()
  defp with_verified_runtime(runtime, %Catalog{} = catalog, opts, function) do
    actions = SpectreKinetic.action_definitions(runtime)
    verification_opts = Keyword.take(opts, [:allow_unmounted_actions])

    with :ok <- Catalog.verify_runtime(catalog, actions, verification_opts) do
      function.(runtime)
    end
  end

  @spec with_temp_registry([map()], keyword(), (term() -> term())) :: term()
  defp with_temp_registry(actions, runtime_opts, function) do
    with {:ok, json} <- Jason.encode(%{"actions" => actions}),
         {:ok, path} <- write_temp_registry(json) do
      try do
        load_and_run(Keyword.put(runtime_opts, :registry_json, path), function)
      after
        File.rm(path)
      end
    else
      {:error, reason} -> {:error, {:provider_registry_failed, reason}}
    end
  end

  @spec write_temp_registry(binary(), non_neg_integer()) ::
          {:ok, Path.t()} | {:error, term()}
  defp write_temp_registry(json, attempts \\ @temp_registry_attempts)

  defp write_temp_registry(_json, 0), do: {:error, :temporary_registry_collision}

  defp write_temp_registry(json, attempts) do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre_kinetic_providers_#{random_suffix()}.json"
      )

    case File.open(path, [:write, :exclusive, :binary], &IO.binwrite(&1, json)) do
      {:ok, :ok} ->
        {:ok, path}

      {:ok, {:error, reason}} ->
        File.rm(path)
        {:error, reason}

      {:error, :eexist} ->
        write_temp_registry(json, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec random_suffix() :: binary()
  defp random_suffix do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec configured_registry?(keyword()) :: boolean()
  defp configured_registry?(opts) do
    Enum.any?(
      [
        Keyword.get(opts, :compiled_registry),
        Keyword.get(opts, :registry_json),
        Application.get_env(:spectre_kinetic, :compiled_registry),
        Application.get_env(:spectre_kinetic, :registry_json),
        System.get_env("SPECTRE_KINETIC_COMPILED_REGISTRY"),
        System.get_env("SPECTRE_KINETIC_REGISTRY_JSON")
      ],
      &(is_binary(&1) and String.trim(&1) != "")
    )
  end

  @spec plan_opts(keyword()) :: keyword()
  defp plan_opts(opts), do: Keyword.take(opts, @plan_option_keys)

  @spec value(map(), atom()) :: term()
  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  @spec plain_map(map()) :: map()
  defp plain_map(%KineticAction{} = action), do: Map.from_struct(action)
  defp plain_map(map) when is_map(map), do: map
end
