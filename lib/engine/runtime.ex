defmodule SpectreKinetic.Runtime do
  @moduledoc false

  @app :spectre_kinetic
  @default_top_k 5
  @default_fallback_top_k 3
  @default_fallback_margin 0.12

  @doc """
  Returns planner defaults merged from application config and environment.
  """
  @spec default_plan_options() :: keyword()
  def default_plan_options do
    [
      top_k: config_integer(:top_k, "SPECTRE_KINETIC_TOP_K", @default_top_k),
      tool_threshold: config_float(:tool_threshold, "SPECTRE_KINETIC_TOOL_THRESHOLD"),
      mapping_threshold: config_float(:mapping_threshold, "SPECTRE_KINETIC_MAPPING_THRESHOLD"),
      tool_selection_fallback:
        config_fallback_mode(
          :tool_selection_fallback,
          "SPECTRE_KINETIC_TOOL_SELECTION_FALLBACK",
          :disabled
        ),
      fallback_top_k:
        config_integer(
          :fallback_top_k,
          "SPECTRE_KINETIC_FALLBACK_TOP_K",
          @default_fallback_top_k
        ),
      fallback_margin:
        config_float(
          :fallback_margin,
          "SPECTRE_KINETIC_FALLBACK_MARGIN",
          @default_fallback_margin
        )
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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
    {:ok,
     %{
       encoder_model_dir:
         resolve_optional_path(
           opts,
           :encoder_model_dir,
           :encoder_model_dir,
           "SPECTRE_KINETIC_ENCODER_MODEL_DIR"
         ),
       compiled_registry:
         resolve_optional_path(
           opts,
           :compiled_registry,
           :compiled_registry,
           "SPECTRE_KINETIC_COMPILED_REGISTRY"
         ),
       registry_json:
         resolve_optional_path(
           opts,
           :registry_json,
           :registry_json,
           "SPECTRE_KINETIC_REGISTRY_JSON"
         ),
       fallback_model_dir:
         resolve_optional_path(
           opts,
           :fallback_model_dir,
           :fallback_model_dir,
           "SPECTRE_KINETIC_FALLBACK_MODEL_DIR"
         )
     }}
  end

  @doc """
  Resolves one optional path from opts, config, or environment.
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

  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: value

  defp stringify_value(value), do: to_string(value)

  defp config_integer(app_key, env_var, default) do
    first_present_integer([Application.get_env(@app, app_key), System.get_env(env_var), default])
  end

  defp config_float(app_key, env_var, default \\ nil) do
    first_present_float([Application.get_env(@app, app_key), System.get_env(env_var), default])
  end

  defp config_fallback_mode(app_key, env_var, default) do
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
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value / 1

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_float(_value), do: nil

  defp parse_fallback_mode(value) when value in [:disabled, :reranker], do: value

  defp parse_fallback_mode(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "disabled" -> :disabled
      "reranker" -> :reranker
      _ -> nil
    end
  end

  defp parse_fallback_mode(_value), do: nil
end
