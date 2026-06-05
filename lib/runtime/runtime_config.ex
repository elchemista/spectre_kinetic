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
  @built_in_plan_defaults [
    top_k: 5,
    tool_threshold: 0.3,
    mapping_threshold: 0.0,
    tool_selection_fallback: :disabled,
    fallback_top_k: 3,
    fallback_margin: 0.12
  ]

  @plan_option_sources [
    {:top_k, :integer, "SPECTRE_KINETIC_TOP_K"},
    {:tool_threshold, :float, "SPECTRE_KINETIC_TOOL_THRESHOLD"},
    {:mapping_threshold, :float, "SPECTRE_KINETIC_MAPPING_THRESHOLD"},
    {:tool_selection_fallback, :fallback_mode, "SPECTRE_KINETIC_TOOL_SELECTION_FALLBACK"},
    {:fallback_top_k, :integer, "SPECTRE_KINETIC_FALLBACK_TOP_K"},
    {:fallback_margin, :float, "SPECTRE_KINETIC_FALLBACK_MARGIN"}
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_optional_request_fields(map, request) do
    [
      {"tool_threshold", :tool_threshold},
      {"mapping_threshold", :mapping_threshold},
      {"tool_selection_fallback", :tool_selection_fallback},
      {"fallback_top_k", :fallback_top_k},
      {"fallback_margin", :fallback_margin}
    ]
    |> Enum.reduce(map, fn {target_key, request_key}, acc ->
      maybe_put(acc, target_key, request_value(request, request_key))
    end)
  end

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
