defmodule SpectreKinetic.RuntimeConfig do
  @moduledoc """
  Normalizes runtime configuration at the library boundary.

  Planner code accepts clean Elixir options. Callers, config files, and
  deployment environments often provide the same values through different
  shapes:

    * per-call keyword options
    * `Application` config under `:spectre_kinetic`
    * `SPECTRE_KINETIC_*` environment variables
    * JSON-like request maps with string keys

  This module is the adapter for those external shapes. It resolves paths,
  parses scalar config values, and converts request payloads before they enter
  the planner pipeline.
  """

  alias SpectreKinetic.ClassifierPipeline.Spec, as: ClassifierSpec

  @app :spectre_kinetic
  @built_in_plan_defaults [
    top_k: 5,
    tool_threshold: 0.3,
    mapping_threshold: 0.0,
    tool_selection_fallback: :disabled,
    fallback_top_k: 3,
    fallback_margin: 0.12,
    reranker_threshold: 0.5
  ]

  @plan_option_sources [
    {:top_k, :integer, "SPECTRE_KINETIC_TOP_K"},
    {:tool_threshold, :float, "SPECTRE_KINETIC_TOOL_THRESHOLD"},
    {:mapping_threshold, :float, "SPECTRE_KINETIC_MAPPING_THRESHOLD"},
    {:tool_selection_fallback, :fallback_mode, "SPECTRE_KINETIC_TOOL_SELECTION_FALLBACK"},
    {:fallback_top_k, :integer, "SPECTRE_KINETIC_FALLBACK_TOP_K"},
    {:fallback_margin, :float, "SPECTRE_KINETIC_FALLBACK_MARGIN"},
    {:reranker_threshold, :float, "SPECTRE_KINETIC_RERANKER_THRESHOLD"}
  ]

  @runtime_path_sources [
    {:encoder_model_dir, "SPECTRE_KINETIC_ENCODER_MODEL_DIR"},
    {:compiled_registry, "SPECTRE_KINETIC_COMPILED_REGISTRY"},
    {:registry_json, "SPECTRE_KINETIC_REGISTRY_JSON"},
    {:fallback_model_dir, "SPECTRE_KINETIC_FALLBACK_MODEL_DIR"}
  ]

  @runtime_path_keys Enum.map(@runtime_path_sources, &elem(&1, 0))
  @runtime_module_keys [:registry_module, :fallback_runtime_module]
  @max_al_bytes 32 * 1_024
  @max_slot_depth 16
  @max_slot_entries 256
  @max_slot_nodes 4_096
  @max_slot_string_bytes 64 * 1_024
  @max_total_slot_string_bytes 1_024 * 1_024

  @doc """
  Returns the planner defaults before application config or environment overrides.
  """
  @spec built_in_plan_defaults() :: keyword()
  def built_in_plan_defaults, do: @built_in_plan_defaults

  @doc """
  Returns planner defaults merged from application config and environment.
  """
  @spec default_plan_options() :: keyword()
  def default_plan_options do
    Enum.map(@plan_option_sources, &resolve_plan_option/1)
  end

  @doc """
  Resolves the canonical planner artifact paths.
  """
  @spec resolve_runtime_paths(keyword()) ::
          {:ok,
           %{
             encoder_model_dir: binary() | nil,
             compiled_registry: binary() | nil,
             registry_json: binary() | nil,
             fallback_model_dir: binary() | nil
           }}
          | {:error, {:invalid_options, [validation_issue()]}}
  def resolve_runtime_paths(opts \\ []) do
    with :ok <- validate_options(opts) do
      do_resolve_runtime_paths(opts)
    end
  end

  defp do_resolve_runtime_paths(opts) do
    Enum.reduce_while(@runtime_path_sources, {:ok, %{}}, fn {key, env_var}, {:ok, paths} ->
      case resolve_path(opts, key, key, env_var) do
        {:ok, path} -> {:cont, {:ok, Map.put(paths, key, path)}}
        {:error, issue} -> {:halt, validation_result(:invalid_options, [issue])}
      end
    end)
  end

  @doc """
  Resolves one optional path from opts, config, or environment.

  Precedence is explicit option, application config, then environment. Blank
  strings are treated as missing values and non-blank paths are expanded.
  """
  @spec resolve_optional_path(keyword(), atom(), atom(), binary()) :: binary() | nil
  def resolve_optional_path(opts, opt_key, app_key, env_var) do
    case resolve_path(opts, opt_key, app_key, env_var) do
      {:ok, path} -> path
      {:error, _issue} -> nil
    end
  end

  @doc """
  Resolves one required path from opts, config, or environment.
  """
  @spec resolve_required_path(keyword(), atom(), atom(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def resolve_required_path(opts, opt_key, app_key, env_var) do
    with {:ok, path} <- resolve_path(opts, opt_key, app_key, env_var) do
      wrap_required_path(path, opt_key, env_var)
    end
  end

  @doc false
  @spec validate_path(term(), atom()) ::
          :ok | {:error, {:invalid_options, [validation_issue()]}}
  def validate_path(path, key) do
    validation_result(:invalid_options, path_value_issues(path, key))
  end

  @doc false
  @spec validate_module(term(), atom()) ::
          :ok | {:error, {:invalid_options, [validation_issue()]}}
  def validate_module(module, key) do
    validation_result(:invalid_options, module_value_issues(module, key))
  end

  @doc """
  Recursively stringifies map keys for request payloads.

  Values are kept JSON-compatible where possible. Booleans and `nil` are
  preserved, while non-boolean atom values become strings so normalized request
  maps can safely cross JSON-style boundaries.
  """
  @spec stringify_map(map()) :: map()
  def stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  def stringify_map(_), do: %{}

  @doc """
  Normalizes a plan request map into the runtime-first request shape.

  The result always contains string keys for `"al"`, `"slots"`, and `"top_k"`.
  Optional thresholds and fallback tuning are copied only when present.
  """
  @spec normalize_request(map()) :: map()
  def normalize_request(request) when is_map(request) do
    %{
      "al" => request_value(request, :al, ""),
      "slots" => request_slots(request),
      "top_k" => request_value(request, :top_k, default_top_k())
    }
    |> put_optional_request_fields(request)
  end

  def normalize_request(_request) do
    %{"al" => "", "slots" => %{}, "top_k" => built_in_default!(:top_k)}
  end

  @typedoc "One machine-readable public input validation issue."
  @type validation_issue :: %{required(:field) => atom(), required(:reason) => atom()}

  @doc """
  Validates an AL value and public planner options before any planner work.

  Errors deliberately contain field names and stable reason atoms rather than
  echoing AL or slot values back to logs and callers.
  """
  @spec validate_plan_input(term(), term()) ::
          :ok | {:error, {:invalid_request | :invalid_options, [validation_issue()]}}
  def validate_plan_input(al, opts) do
    with :ok <- validation_result(:invalid_request, al_issues(al)),
         :ok <- validate_options(opts) do
      :ok
    end
  end

  @doc """
  Validates the external request-map shape accepted by `plan_request/2`.
  """
  @spec validate_request(term()) ::
          :ok | {:error, {:invalid_request, [validation_issue()]}}
  def validate_request(request) when is_map(request) and not is_struct(request) do
    errors =
      al_issues(request_value(request, :al)) ++
        slots_issues(request_value(request, :slots, %{})) ++
        request_option_issues(request)

    validation_result(:invalid_request, errors)
  end

  def validate_request(_request) do
    validation_result(:invalid_request, [%{field: :request, reason: :must_be_map}])
  end

  @doc """
  Validates planner option containers and the bounded numeric options they expose.

  Both keyword lists and atom-keyed maps are accepted because the public facade
  uses keywords while the internal planner uses maps.
  """
  @spec validate_options(term()) ::
          :ok | {:error, {:invalid_options, [validation_issue()]}}
  def validate_options(opts) do
    case options_map(opts) do
      {:ok, options} -> validation_result(:invalid_options, option_issues(options, :options))
      {:error, issue} -> validation_result(:invalid_options, [issue])
    end
  end

  @doc """
  Formats a readable error message for missing required paths.
  """
  @spec missing_path_message({:missing_path, atom(), binary()}) :: binary()
  def missing_path_message({:missing_path, key, env_var}) do
    "missing required #{inspect(key)}. Pass it explicitly, configure :#{key} for :spectre_kinetic, or export #{env_var}."
  end

  defp resolve_path(opts, opt_key, app_key, env_var) do
    [Keyword.get(opts, opt_key), Application.get_env(@app, app_key), System.get_env(env_var)]
    |> Enum.find(&path_candidate?/1)
    |> normalize_optional_path(opt_key)
  end

  defp path_candidate?(nil), do: false
  defp path_candidate?(value) when is_binary(value), do: String.trim(value) != ""
  defp path_candidate?(_value), do: true

  defp normalize_optional_path(nil, _key), do: {:ok, nil}

  defp normalize_optional_path(path, _key) when is_binary(path),
    do: {:ok, Path.expand(path)}

  defp normalize_optional_path(_path, key),
    do: {:error, %{field: key, reason: :must_be_non_blank_binary}}

  defp wrap_required_path(nil, opt_key, env_var), do: {:error, {:missing_path, opt_key, env_var}}
  defp wrap_required_path(path, _opt_key, _env_var), do: {:ok, path}

  defp stringify_value(nil), do: nil
  defp stringify_value(value) when is_boolean(value), do: value
  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)

  defp stringify_value(value) when is_integer(value) or is_float(value),
    do: value

  defp stringify_value(value), do: to_string(value)

  defp resolve_plan_option({key, parser, env_var}) do
    {key, config_value(key, parser, env_var, built_in_default!(key))}
  end

  defp config_value(app_key, :integer, env_var, default) do
    first_present_integer([Application.get_env(@app, app_key), System.get_env(env_var), default])
  end

  defp config_value(app_key, :float, env_var, default) do
    first_present_float([Application.get_env(@app, app_key), System.get_env(env_var), default])
  end

  defp config_value(app_key, :fallback_mode, env_var, default) do
    [Application.get_env(@app, app_key), System.get_env(env_var), default]
    |> Enum.find_value(&parse_fallback_mode/1)
  end

  defp first_present_integer(values) do
    Enum.find_value(values, &parse_integer/1)
  end

  defp first_present_float(values) do
    Enum.find_value(values, &parse_float/1)
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    value
    |> Integer.parse()
    |> parse_integer_result()
  end

  defp parse_integer(_value), do: nil
  defp parse_integer_result({parsed, ""}), do: parsed
  defp parse_integer_result(_result), do: nil

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value / 1

  defp parse_float(value) when is_binary(value) do
    value
    |> Float.parse()
    |> parse_float_result()
  end

  defp parse_float(_value), do: nil
  defp parse_float_result({parsed, ""}), do: parsed
  defp parse_float_result(_result), do: nil

  defp parse_fallback_mode(value) when value in [:disabled, :reranker], do: value

  defp parse_fallback_mode(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> parse_fallback_mode_result()
  end

  defp parse_fallback_mode(_value), do: nil
  defp parse_fallback_mode_result("disabled"), do: :disabled
  defp parse_fallback_mode_result("reranker"), do: :reranker
  defp parse_fallback_mode_result(_value), do: nil

  defp al_issues(al) when is_binary(al) do
    cond do
      not String.valid?(al) ->
        [%{field: :al, reason: :must_be_utf8_binary}]

      byte_size(al) > @max_al_bytes ->
        [%{field: :al, reason: :exceeds_size_limit}]

      true ->
        case SpectreKinetic.Parser.validate(al) do
          {:ok, _normalized} -> []
          {:error, reason} -> [%{field: :al, reason: reason}]
        end
    end
  end

  defp al_issues(_al), do: [%{field: :al, reason: :must_be_binary}]

  defp slots_issues(slots) when is_map(slots) and not is_struct(slots) do
    budget = %{nodes: @max_slot_nodes, string_bytes: @max_total_slot_string_bytes}

    case validate_slot_map(slots, 0, budget) do
      {:ok, _remaining_budget} -> []
      {:error, :limit} -> [%{field: :slots, reason: :exceeds_complexity_limit}]
      {:error, :invalid} -> [%{field: :slots, reason: :must_be_json_compatible_map}]
    end
  end

  defp slots_issues(_slots), do: [%{field: :slots, reason: :must_be_map}]

  defp request_option_issues(request) do
    request
    |> request_options_map()
    |> option_issues(:request)
  end

  defp request_options_map(request) do
    [
      :top_k,
      :tool_threshold,
      :mapping_threshold,
      :tool_selection_fallback,
      :fallback_top_k,
      :fallback_margin,
      :reranker_threshold
    ]
    |> Enum.reduce(%{}, fn key, options ->
      case fetch_request_value(request, key) do
        {:ok, value} -> Map.put(options, key, value)
        :error -> options
      end
    end)
  end

  defp option_issues(options, source) do
    slots_issues_if_present(options) ++
      positive_integer_issues(options, :top_k) ++
      probability_issues(options, :tool_threshold) ++
      probability_issues(options, :mapping_threshold) ++
      fallback_mode_issues(options, source) ++
      positive_integer_issues(options, :fallback_top_k) ++
      probability_issues(options, :fallback_margin) ++
      probability_issues(options, :reranker_threshold) ++
      runtime_path_issues(options) ++
      runtime_module_issues(options) ++
      classifier_issues(options) ++
      boolean_option_issues(options, :allow_empty_registry)
  end

  defp slots_issues_if_present(options) do
    case Map.fetch(options, :slots) do
      :error -> []
      {:ok, slots} -> slots_issues(slots)
    end
  end

  defp positive_integer_issues(options, key) do
    case Map.fetch(options, key) do
      :error -> []
      {:ok, value} when is_integer(value) and value > 0 -> []
      {:ok, _value} -> [%{field: key, reason: :must_be_positive_integer}]
    end
  end

  defp probability_issues(options, key) do
    case Map.fetch(options, key) do
      :error -> []
      {:ok, value} when is_number(value) -> probability_value_issues(key, value)
      {:ok, _value} -> [%{field: key, reason: :must_be_probability}]
    end
  end

  defp probability_value_issues(key, value) do
    if value == value and value >= 0.0 and value <= 1.0 do
      []
    else
      [%{field: key, reason: :must_be_probability}]
    end
  end

  defp fallback_mode_issues(options, source) do
    case Map.fetch(options, :tool_selection_fallback) do
      :error ->
        []

      {:ok, value} ->
        if valid_fallback_mode?(value, source) do
          []
        else
          [%{field: :tool_selection_fallback, reason: :must_be_fallback_mode}]
        end
    end
  end

  defp valid_fallback_mode?(value, :options), do: value in [:disabled, :reranker]
  defp valid_fallback_mode?(value, :request), do: not is_nil(parse_fallback_mode(value))

  defp runtime_path_issues(options) do
    Enum.flat_map(@runtime_path_keys, fn key ->
      case Map.fetch(options, key) do
        :error -> []
        {:ok, value} -> path_value_issues(value, key)
      end
    end)
  end

  defp path_value_issues(value, key) when is_binary(value) do
    if String.trim(value) == "" do
      [%{field: key, reason: :must_be_non_blank_binary}]
    else
      []
    end
  end

  defp path_value_issues(_value, key),
    do: [%{field: key, reason: :must_be_non_blank_binary}]

  defp runtime_module_issues(options) do
    Enum.flat_map(@runtime_module_keys, fn key ->
      case Map.fetch(options, key) do
        :error -> []
        {:ok, module} -> module_value_issues(module, key)
      end
    end)
  end

  defp module_value_issues(module, key) when is_atom(module) do
    if Code.ensure_loaded?(module), do: [], else: [%{field: key, reason: :must_be_module}]
  end

  defp module_value_issues(_module, key), do: [%{field: key, reason: :must_be_module}]

  defp classifier_issues(options) do
    case Map.fetch(options, :classifiers) do
      :error ->
        []

      {:ok, classifiers} when is_list(classifiers) ->
        if Enum.all?(classifiers, &valid_classifier_spec?/1) do
          []
        else
          [%{field: :classifiers, reason: :invalid_classifier_spec}]
        end

      {:ok, _classifiers} ->
        [%{field: :classifiers, reason: :must_be_list}]
    end
  end

  defp valid_classifier_spec?(%ClassifierSpec{module: module}),
    do: valid_classifier_module?(module, :initialized)

  defp valid_classifier_spec?(module) when is_atom(module),
    do: valid_classifier_module?(module, :declaration)

  defp valid_classifier_spec?({module, opts}) when is_atom(module) and is_list(opts) do
    Keyword.keyword?(opts) and valid_classifier_module?(module, :declaration)
  end

  defp valid_classifier_spec?(_spec), do: false

  defp valid_classifier_module?(module, mode) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :call, 2) and
      (mode == :initialized or function_exported?(module, :init, 1))
  end

  defp valid_classifier_module?(_module, _mode), do: false

  defp boolean_option_issues(options, key) do
    case Map.fetch(options, key) do
      :error -> []
      {:ok, value} when is_boolean(value) -> []
      {:ok, _value} -> [%{field: key, reason: :must_be_boolean}]
    end
  end

  defp options_map(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, %{field: :options, reason: :must_be_keyword_or_atom_keyed_map}}

      duplicate_keyword_keys?(opts) ->
        {:error, %{field: :options, reason: :must_have_unique_keys}}

      true ->
        {:ok, Map.new(opts)}
    end
  end

  defp options_map(opts) when is_map(opts) and not is_struct(opts) do
    if Enum.all?(Map.keys(opts), &is_atom/1) do
      {:ok, opts}
    else
      {:error, %{field: :options, reason: :must_be_keyword_or_atom_keyed_map}}
    end
  end

  defp options_map(_opts) do
    {:error, %{field: :options, reason: :must_be_keyword_or_atom_keyed_map}}
  end

  defp duplicate_keyword_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp validate_slot_map(_slots, depth, _budget) when depth > @max_slot_depth,
    do: {:error, :limit}

  defp validate_slot_map(slots, _depth, _budget) when map_size(slots) > @max_slot_entries,
    do: {:error, :limit}

  defp validate_slot_map(slots, depth, budget) do
    with {:ok, budget} <- consume_slot_node(budget) do
      Enum.reduce_while(slots, {:ok, budget}, fn {key, value}, {:ok, remaining} ->
        with {:ok, remaining} <- validate_slot_key(key, remaining),
             {:ok, next} <- validate_slot_value(value, depth + 1, remaining) do
          {:cont, {:ok, next}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_slot_key(key, budget) when is_atom(key), do: consume_slot_node(budget)

  defp validate_slot_key(key, budget) when is_binary(key) do
    cond do
      not String.valid?(key) -> {:error, :invalid}
      byte_size(key) > @max_slot_string_bytes -> {:error, :limit}
      true -> consume_slot_string(budget, byte_size(key))
    end
  end

  defp validate_slot_key(_key, _budget), do: {:error, :invalid}

  defp validate_slot_value(_value, depth, _budget) when depth > @max_slot_depth,
    do: {:error, :limit}

  defp validate_slot_value(value, _depth, budget)
       when is_nil(value) or is_boolean(value) or is_atom(value) or is_integer(value),
       do: consume_slot_node(budget)

  defp validate_slot_value(value, _depth, budget) when is_float(value) do
    if finite_float?(value), do: consume_slot_node(budget), else: {:error, :invalid}
  end

  defp validate_slot_value(value, _depth, budget) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid}
      byte_size(value) > @max_slot_string_bytes -> {:error, :limit}
      true -> consume_slot_string(budget, byte_size(value))
    end
  end

  defp validate_slot_value(value, depth, budget)
       when is_map(value) and not is_struct(value),
       do: validate_slot_map(value, depth, budget)

  defp validate_slot_value([], _depth, budget), do: consume_slot_node(budget)

  defp validate_slot_value([_head | _tail] = value, depth, budget) do
    with {:ok, budget} <- consume_slot_node(budget) do
      validate_slot_list(value, depth, budget, 0)
    end
  end

  defp validate_slot_value(_value, _depth, _budget), do: {:error, :invalid}

  defp validate_slot_list([], _depth, budget, _count), do: {:ok, budget}

  defp validate_slot_list([_head | _tail], _depth, _budget, @max_slot_entries),
    do: {:error, :limit}

  defp validate_slot_list([head | tail], depth, budget, count) do
    with {:ok, budget} <- validate_slot_value(head, depth + 1, budget) do
      validate_slot_list(tail, depth, budget, count + 1)
    end
  end

  defp validate_slot_list(_improper_tail, _depth, _budget, _count),
    do: {:error, :invalid}

  defp consume_slot_node(%{nodes: nodes} = budget) when nodes > 0,
    do: {:ok, %{budget | nodes: nodes - 1}}

  defp consume_slot_node(_budget), do: {:error, :limit}

  defp consume_slot_string(%{string_bytes: remaining} = budget, size)
       when size <= remaining do
    with {:ok, budget} <- consume_slot_node(budget) do
      {:ok, %{budget | string_bytes: remaining - size}}
    end
  end

  defp consume_slot_string(_budget, _size), do: {:error, :limit}

  defp finite_float?(value) do
    representation = value |> :erlang.float_to_binary([:compact]) |> String.downcase()
    representation not in ["nan", "inf", "-inf"]
  rescue
    _error -> false
  end

  defp validation_result(_scope, []), do: :ok
  defp validation_result(scope, errors), do: {:error, {scope, errors}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_optional_request_fields(map, request) do
    [
      {"tool_threshold", :tool_threshold},
      {"mapping_threshold", :mapping_threshold},
      {"tool_selection_fallback", :tool_selection_fallback},
      {"fallback_top_k", :fallback_top_k},
      {"fallback_margin", :fallback_margin},
      {"reranker_threshold", :reranker_threshold}
    ]
    |> Enum.reduce(map, fn {target_key, request_key}, acc ->
      value = request |> request_value(request_key) |> normalize_request_option(request_key)
      maybe_put(acc, target_key, value)
    end)
  end

  defp normalize_request_option(value, :tool_selection_fallback) do
    parse_fallback_mode(value) || value
  end

  defp normalize_request_option(value, _request_key), do: value

  defp request_slots(request) do
    request
    |> request_value(:slots, %{})
    |> stringify_map()
  end

  defp request_value(request, key, default \\ nil) do
    case fetch_request_value(request, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_request_value(request, key) do
    [key, Atom.to_string(key)]
    |> Enum.find_value(:error, &fetch_present_value(request, &1))
  end

  defp fetch_present_value(request, key) do
    if Map.has_key?(request, key) do
      non_nil_value(Map.get(request, key))
    end
  end

  defp non_nil_value(nil), do: nil
  defp non_nil_value(value), do: {:ok, value}

  defp default_top_k do
    Keyword.get(default_plan_options(), :top_k, built_in_default!(:top_k))
  end

  defp built_in_default!(key), do: Keyword.fetch!(@built_in_plan_defaults, key)
end
