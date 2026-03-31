defmodule SpectreKinetic.Runtime do
  @moduledoc false

  @app :spectre_kinetic
  @default_top_k 5

  @doc """
  Returns default planner options merged from application config and environment.
  """
  @spec default_plan_options() :: keyword()
  def default_plan_options do
    [
      top_k: config_integer(:top_k, "SPECTRE_KINETIC_TOP_K", @default_top_k),
      tool_threshold: default_tool_threshold(),
      mapping_threshold: config_float(:mapping_threshold, "SPECTRE_KINETIC_MAPPING_THRESHOLD")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Returns the configured tool-selection threshold, if any.
  """
  @spec default_tool_threshold() :: float() | nil
  def default_tool_threshold do
    first_present_float([
      Application.get_env(@app, :tool_threshold),
      Application.get_env(@app, :confidence_threshold),
      Application.get_env(@app, :confidence),
      System.get_env("SPECTRE_KINETIC_TOOL_THRESHOLD"),
      System.get_env("SPECTRE_KINETIC_CONFIDENCE_THRESHOLD"),
      System.get_env("SPECTRE_KINETIC_CONFIDENCE")
    ])
  end

  @doc """
  Resolves the required runtime paths for model and compiled registry.
  """
  @spec resolve_runtime_paths(keyword()) ::
          {:ok, %{model_dir: binary(), registry_mcr: binary()}} | {:error, term()}
  def resolve_runtime_paths(opts) do
    with {:ok, model_dir} <-
           resolve_path(opts, :model_dir, :model_dir, "SPECTRE_KINETIC_MODEL_DIR"),
         {:ok, registry_mcr} <-
           resolve_path(opts, :registry_mcr, :registry_mcr, "SPECTRE_KINETIC_REGISTRY_MCR") do
      {:ok, %{model_dir: model_dir, registry_mcr: registry_mcr}}
    end
  end

  @doc """
  Resolves the required runtime paths and raises on failure.
  """
  @spec resolve_runtime_paths!(keyword()) :: %{model_dir: binary(), registry_mcr: binary()}
  def resolve_runtime_paths!(opts \\ []) do
    case resolve_runtime_paths(opts) do
      {:ok, paths} -> paths
      {:error, reason} -> raise ArgumentError, missing_path_message(reason)
    end
  end

  @doc """
  Resolves one optional path from call-site opts, app config, or environment.
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
  Resolves one required path from call-site opts, app config, or environment.
  """
  @spec resolve_path(keyword(), atom(), atom(), binary()) :: {:ok, binary()} | {:error, term()}
  def resolve_path(opts, opt_key, app_key, env_var),
    do:
      resolve_optional_path(opts, opt_key, app_key, env_var)
      |> wrap_required_path(opt_key, env_var)

  @doc """
  Recursively stringifies map keys for JSON payloads passed into Rust.
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

  defp config_float(app_key, env_var) do
    first_present_float([Application.get_env(@app, app_key), System.get_env(env_var)])
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
end
