defmodule Spectre.Kinetic.Actions do
  @moduledoc """
  Built-in Spectre action provider for modules declared with `use SpectreKinetic`.

  Applications mount it indirectly:

      use Spectre.Agent
      use Spectre.Kinetic, actions: MyApp.Actions

  Kinetic owns extraction and positional invocation for the annotated module;
  Spectre still owns staging, policy, persistence, and provider dispatch.
  """

  alias SpectreKinetic.Tool.Extractor

  @doc false
  @spec actions(keyword()) :: [map()] | {:error, term()}
  def actions(opts) do
    with {:ok, module} <- action_module(opts),
         {:ok, entries} <- Extractor.extract_module(module) do
      Enum.map(entries, &action_spec(&1, module, opts))
    end
  end

  @doc false
  @spec execute(map(), map(), keyword()) :: term()
  def execute(action, _ctx, opts) when is_map(action) do
    with {:ok, module} <- action_module(opts),
         {:ok, entries} <- Extractor.extract_module(module),
         {:ok, entry} <- resolve_entry(action, entries, module, opts),
         {:ok, function} <- existing_function(entry["name"]),
         :ok <- ensure_exported(module, function, entry["arity"]),
         {:ok, values} <- ordered_args(entry["args"], action_value(action, :args)) do
      apply(module, function, values)
    end
  end

  @spec action_spec(map(), module(), keyword()) :: map()
  defp action_spec(entry, module, opts) do
    name = existing_name(entry["name"])

    %{
      name: name,
      description: entry["doc"],
      mode: action_mode(name, opts),
      schema: %{
        args: entry["args"],
        executor: %{
          module: module,
          function: name,
          arity: entry["arity"]
        }
      },
      metadata: %{
        examples: entry["examples"],
        kinetic: true,
        kinetic_registry: entry
      }
    }
  end

  @spec resolve_entry(map(), [map()], module(), keyword()) :: {:ok, map()} | {:error, term()}
  defp resolve_entry(action, entries, module, opts) do
    expected_hash = action_value(action, :schema_hash)
    expected_name = action_value(action, :name)

    matches =
      Enum.filter(entries, fn entry ->
        spec = action_spec(entry, module, opts)

        comparable_name(spec.name) == comparable_name(expected_name) and
          (is_nil(expected_hash) or spec_hash(spec, opts) == expected_hash)
      end)

    case matches do
      [entry] ->
        {:ok, entry}

      [] ->
        {:error, {:unknown_kinetic_action, module, expected_name, expected_hash}}

      _entries ->
        {:error, {:ambiguous_kinetic_action, module, expected_name, expected_hash}}
    end
  end

  @spec spec_hash(map(), keyword()) :: String.t() | nil
  defp spec_hash(spec, opts) do
    spec_module = Module.concat(["Spectre", "Action", "Spec"])
    provider_id = Keyword.get(opts, :provider_id, :kinetic)

    if Code.ensure_loaded?(spec_module) and function_exported?(spec_module, :new, 1) do
      spec
      |> Map.put(:via, provider_id)
      |> then(&spec_module.new(&1))
      |> Map.get(:schema_hash)
    end
  end

  @spec ordered_args([map()], map()) :: {:ok, [term()]} | {:error, term()}
  defp ordered_args(definitions, args) when is_list(definitions) and is_map(args) do
    definitions
    |> Enum.reduce_while({:ok, []}, fn definition, {:ok, values} ->
      name = Map.get(definition, "name") || Map.get(definition, :name)
      required = Map.get(definition, "required", Map.get(definition, :required, true))

      case fetch_arg(args, name) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        :error when required -> {:halt, {:error, {:missing_action_argument, name}}}
        :error -> {:cont, {:ok, [nil | values]}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_args(_definitions, args), do: {:error, {:invalid_action_args, args}}

  @spec fetch_arg(map(), String.t() | atom()) :: {:ok, term()} | :error
  defp fetch_arg(args, name) do
    case Map.fetch(args, name) do
      {:ok, _value} = found ->
        found

      :error when is_binary(name) ->
        fetch_existing_atom(args, name)

      :error when is_atom(name) ->
        Map.fetch(args, Atom.to_string(name))

      :error ->
        :error
    end
  end

  @spec fetch_existing_atom(map(), String.t()) :: {:ok, term()} | :error
  defp fetch_existing_atom(args, name) do
    Map.fetch(args, String.to_existing_atom(name))
  rescue
    ArgumentError -> :error
  end

  @spec action_module(keyword()) :: {:ok, module()} | {:error, term()}
  defp action_module(opts) do
    case Keyword.get(opts, :module) do
      module when is_atom(module) and not is_nil(module) ->
        cond do
          not Code.ensure_loaded?(module) ->
            {:error, {:unknown_kinetic_actions_module, module}}

          not function_exported?(module, :__spectre_tools__, 0) ->
            {:error, {:kinetic_actions_module_not_annotated, module}}

          true ->
            {:ok, module}
        end

      other ->
        {:error, {:invalid_kinetic_actions_module, other}}
    end
  end

  @spec action_mode(atom() | String.t(), keyword()) :: atom() | nil
  defp action_mode(name, opts) do
    modes = Keyword.get(opts, :modes, %{})

    mode_for(modes, name) ||
      mode_for(modes, comparable_name(name)) ||
      Keyword.get(opts, :mode)
  end

  @spec mode_for(map() | keyword(), atom() | String.t()) :: atom() | nil
  defp mode_for(modes, name) when is_map(modes), do: Map.get(modes, name)

  defp mode_for(modes, name) when is_list(modes) do
    if Keyword.keyword?(modes) and is_atom(name), do: Keyword.get(modes, name)
  end

  defp mode_for(_modes, _name), do: nil

  @spec existing_function(String.t()) :: {:ok, atom()} | {:error, term()}
  defp existing_function(function) when is_binary(function) do
    {:ok, String.to_existing_atom(function)}
  rescue
    ArgumentError -> {:error, {:unknown_kinetic_action_name, function}}
  end

  @spec ensure_exported(module(), atom(), non_neg_integer()) :: :ok | {:error, term()}
  defp ensure_exported(module, function, arity) do
    if function_exported?(module, function, arity),
      do: :ok,
      else: {:error, {:undefined_kinetic_action, module, function, arity}}
  end

  @spec action_value(map(), atom()) :: term()
  defp action_value(action, key),
    do: Map.get(action, key) || Map.get(action, Atom.to_string(key))

  @spec existing_name(String.t()) :: atom() | String.t()
  defp existing_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  @spec comparable_name(term()) :: term()
  defp comparable_name(name) when is_atom(name), do: Atom.to_string(name)
  defp comparable_name(name), do: name
end
