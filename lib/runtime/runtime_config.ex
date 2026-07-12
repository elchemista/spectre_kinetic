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

  @app :spectre_kinetic
  @missing :__spectre_kinetic_missing__
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
  def resolve_runtime_paths(opts \\ []) do
    paths =
      Map.new(@runtime_path_sources, fn {key, env_var} ->
        {key, resolve_optional_path(opts, key, key, env_var)}
      end)

    {:ok, paths}
  end

  @doc """
  Resolves one optional path from opts, config, or environment.

  Precedence is explicit option, application config, then environment. Blank
  strings are treated as missing values and non-blank paths are expanded.
  """
  @spec resolve_optional_path(keyword(), atom(), atom(), binary()) :: binary() | nil
  def resolve_optional_path(opts, opt_key, app_key, env_var) do
    opts
    |> Keyword.get(opt_key)
    |> fallback_path(Application.get_env(@app, app_key))
    |> fallback_path(System.get_env(env_var))
    |> normalize_optional_path()
  end

  @doc """
  Resolves one required path from opts, config, or environment.
  """
  @spec resolve_required_path(keyword(), atom(), atom(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def resolve_required_path(opts, opt_key, app_key, env_var) do
    opts
    |> resolve_optional_path(opt_key, app_key, env_var)
    |> wrap_required_path(opt_key, env_var)
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
      al_issues(request_value(request, :al, @missing)) ++
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

  defp fallback_path(nil, fallback), do: fallback
  defp fallback_path("", fallback), do: fallback
  defp fallback_path(value, _fallback), do: value

  defp normalize_optional_path(nil), do: nil
  defp normalize_optional_path(""), do: nil
  defp normalize_optional_path(path), do: Path.expand(path)

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
    if String.valid?(al) do
      case SpectreKinetic.Parser.validate(al) do
        {:ok, _normalized} -> []
        {:error, reason} -> [%{field: :al, reason: reason}]
      end
    else
      [%{field: :al, reason: :must_be_utf8_binary}]
    end
  end

  defp al_issues(_al), do: [%{field: :al, reason: :must_be_binary}]

  defp slots_issues(slots) when is_map(slots) and not is_struct(slots) do
    if json_compatible_slots?(slots) do
      []
    else
      [%{field: :slots, reason: :must_be_json_compatible_map}]
    end
  end

  defp slots_issues(_slots), do: [%{field: :slots, reason: :must_be_map}]

  defp request_option_issues(request) do
    request
    |> request_options_map()
    |> option_issues(:request)
  end

  defp request_options_map(request) do
    Map.new(
      [
        :top_k,
        :tool_threshold,
        :mapping_threshold,
        :tool_selection_fallback,
        :fallback_top_k,
        :fallback_margin,
        :reranker_threshold
      ],
      fn key -> {key, request_value(request, key, @missing)} end
    )
  end

  defp option_issues(options, source) do
    slots_issues_if_present(options) ++
      positive_integer_issues(options, :top_k) ++
      probability_issues(options, :tool_threshold) ++
      probability_issues(options, :mapping_threshold) ++
      fallback_mode_issues(options, source) ++
      positive_integer_issues(options, :fallback_top_k) ++
      probability_issues(options, :fallback_margin) ++
      probability_issues(options, :reranker_threshold)
  end

  defp slots_issues_if_present(options) do
    case Map.get(options, :slots, @missing) do
      @missing -> []
      slots -> slots_issues(slots)
    end
  end

  defp positive_integer_issues(options, key) do
    case Map.get(options, key, @missing) do
      @missing -> []
      value when is_integer(value) and value > 0 -> []
      _value -> [%{field: key, reason: :must_be_positive_integer}]
    end
  end

  defp probability_issues(options, key) do
    case Map.get(options, key, @missing) do
      @missing -> []
      value when is_number(value) -> probability_value_issues(key, value)
      _value -> [%{field: key, reason: :must_be_probability}]
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
    case Map.get(options, :tool_selection_fallback, @missing) do
      @missing ->
        []

      value ->
        if valid_fallback_mode?(value, source) do
          []
        else
          [%{field: :tool_selection_fallback, reason: :must_be_fallback_mode}]
        end
    end
  end

  defp valid_fallback_mode?(value, :options), do: value in [:disabled, :reranker]
  defp valid_fallback_mode?(value, :request), do: not is_nil(parse_fallback_mode(value))

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

  defp json_compatible_slots?(slots) do
    Enum.all?(slots, fn {key, value} ->
      valid_slot_key?(key) and json_compatible_slot_value?(value)
    end)
  end

  defp valid_slot_key?(key) when is_atom(key), do: true
  defp valid_slot_key?(key) when is_binary(key), do: String.valid?(key)
  defp valid_slot_key?(_key), do: false

  defp json_compatible_slot_value?(nil), do: true
  defp json_compatible_slot_value?(value) when is_boolean(value), do: true
  defp json_compatible_slot_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_compatible_slot_value?(value) when is_atom(value), do: true
  defp json_compatible_slot_value?(value) when is_integer(value), do: true

  defp json_compatible_slot_value?(value) when is_float(value),
    do: value == value

  defp json_compatible_slot_value?([]), do: true

  defp json_compatible_slot_value?([head | tail]),
    do: json_compatible_slot_value?(head) and json_compatible_slot_list_tail?(tail)

  defp json_compatible_slot_value?(value) when is_map(value) and not is_struct(value),
    do: json_compatible_slots?(value)

  defp json_compatible_slot_value?(_value), do: false

  defp json_compatible_slot_list_tail?([]), do: true

  defp json_compatible_slot_list_tail?([head | tail]),
    do: json_compatible_slot_value?(head) and json_compatible_slot_list_tail?(tail)

  defp json_compatible_slot_list_tail?(_improper_tail), do: false

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
