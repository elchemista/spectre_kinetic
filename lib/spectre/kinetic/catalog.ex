defmodule Spectre.Kinetic.Catalog do
  @moduledoc false

  defstruct actions: [], targets: %{}, exact_tools: %{}

  @type target :: %{
          required(:via) => term(),
          required(:name) => atom() | String.t(),
          optional(:mode) => atom() | nil,
          optional(:schema_hash) => String.t() | nil,
          optional(:metadata) => map()
        }

  @type t :: %__MODULE__{
          actions: [map()],
          targets: %{optional(String.t()) => target()},
          exact_tools: %{optional(String.t()) => String.t()}
        }

  @typedoc "Argument aliases declared in provider metadata, keyed by argument name."
  @type aliases :: %{optional(String.t()) => [term()]}

  @doc """
  Builds a Kinetic registry plus the trusted reverse mapping to Spectre
  provider/action references.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :action_providers, []) do
        providers when is_list(providers) ->
          providers
          |> Enum.reduce_while({:ok, %__MODULE__{}}, &add_provider/2)
          |> finalize_catalog()

        providers ->
          {:error, {:invalid_action_providers, providers}}
      end
    else
      {:error, {:invalid_catalog_options, opts}}
    end
  end

  def build(opts), do: {:error, {:invalid_catalog_options, opts}}

  @spec resolve(t(), String.t()) :: {:ok, target()} | {:error, term()}
  def resolve(%__MODULE__{targets: targets}, selected_tool) when is_binary(selected_tool) do
    case Map.get(targets, selected_tool) do
      nil -> {:error, {:unmapped_action_provider, selected_tool}}
      target -> {:ok, target}
    end
  end

  @doc """
  Verifies that a runtime registry still contains the action definitions
  compiled from the Agent's mounted providers.
  """
  @spec verify_runtime(t(), [map()]) :: :ok | {:error, term()}
  def verify_runtime(%__MODULE__{actions: expected}, runtime_actions)
      when is_list(runtime_actions) do
    with {:ok, actual} <- runtime_action_map(runtime_actions),
         :ok <- verify_expected_actions(expected, actual) do
      verify_no_extra_actions(expected, actual)
    end
  end

  def verify_runtime(%__MODULE__{}, runtime_actions),
    do: {:error, {:invalid_kinetic_runtime_actions, runtime_actions}}

  @spec verify_expected_actions([map()], %{String.t() => map()}) ::
          :ok | {:error, term()}
  defp verify_expected_actions(expected, actual) do
    Enum.reduce_while(expected, :ok, fn action, :ok ->
      id = action["id"]

      case Map.fetch(actual, id) do
        {:ok, ^action} -> {:cont, :ok}
        {:ok, other} -> {:halt, {:error, {:kinetic_action_schema_changed, id, other}}}
        :error -> {:halt, {:error, {:kinetic_action_missing, id}}}
      end
    end)
  end

  @spec verify_no_extra_actions([map()], %{String.t() => map()}) :: :ok | {:error, term()}
  defp verify_no_extra_actions(expected, actual) do
    expected_ids = MapSet.new(expected, & &1["id"])

    case Enum.find(Map.keys(actual), &(not MapSet.member?(expected_ids, &1))) do
      nil -> :ok
      id -> {:error, {:kinetic_action_not_mounted, id}}
    end
  end

  @spec exact_tool(t(), String.t() | nil) :: String.t() | nil
  def exact_tool(%__MODULE__{}, nil), do: nil

  def exact_tool(%__MODULE__{exact_tools: exact_tools}, al) when is_binary(al),
    do: Map.get(exact_tools, normalize_al(al))

  @spec add_provider(term(), {:ok, t()}) :: {:cont, {:ok, t()}} | {:halt, {:error, term()}}
  defp add_provider(mount, {:ok, catalog}) when is_map(mount) do
    with :ok <- validate_mount(mount),
         {:ok, specs} <- provider_specs(mount),
         {:ok, entries} <- provider_entries(mount, specs),
         {:ok, catalog} <- merge_entries(catalog, entries) do
      {:cont, {:ok, catalog}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp add_provider(mount, {:ok, _catalog}),
    do: {:halt, {:error, {:invalid_action_provider_mount, mount}}}

  @spec validate_mount(map()) :: :ok | {:error, term()}
  defp validate_mount(mount) do
    mount_module = Module.concat(["Spectre", "Action", "Provider", "Mount"])

    if Map.get(mount, :__struct__) == mount_module and Map.has_key?(mount, :id),
      do: :ok,
      else: {:error, {:invalid_action_provider_mount, mount}}
  end

  @spec provider_specs(map()) :: {:ok, [map()]} | {:error, term()}
  defp provider_specs(mount) do
    provider = Module.concat(["Spectre", "Action", "Provider"])

    if Code.ensure_loaded?(provider) and function_exported?(provider, :actions, 1) do
      case provider.actions(mount) do
        {:ok, specs} when is_list(specs) -> {:ok, Enum.map(specs, &plain_map/1)}
        {:ok, specs} -> {:error, {:invalid_action_provider_specs, specs}}
        {:error, _reason} = error -> error
        other -> {:error, {:invalid_action_provider_reply, other}}
      end
    else
      {:error, :spectre_action_provider_not_loaded}
    end
  end

  @spec provider_entries(map(), [map()]) :: {:ok, [{map(), target()}]} | {:error, term()}
  defp provider_entries(mount, specs), do: generic_entries(mount, specs)

  @spec generic_entries(map(), [map()]) :: {:ok, [{map(), target()}]} | {:error, term()}
  defp generic_entries(mount, specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, entries} ->
      case generic_entry(mount, spec) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  @spec generic_entry(map(), map()) :: {:ok, {map(), target()}} | {:error, term()}
  defp generic_entry(mount, spec) do
    via = Map.fetch!(mount, :id)
    name = spec_value(spec, :name)
    action = planner_action(via, name, spec)

    with {:ok, action} <- SpectreKinetic.Planner.Registry.normalize_action(action) do
      {:ok,
       {action,
        %{
          via: via,
          name: name,
          mode: spec_value(spec, :mode),
          schema_hash: spec_value(spec, :schema_hash),
          metadata: spec_value(spec, :metadata) || %{}
        }}}
    end
  end

  @spec planner_action(term(), atom() | String.t(), map()) :: map()
  defp planner_action(via, name, spec) do
    metadata = spec_value(spec, :metadata) || %{}

    case spec_value(metadata, :kinetic_registry) do
      action when is_map(action) ->
        action

      _other ->
        generic_planner_action(via, name, spec)
    end
  end

  @spec generic_planner_action(term(), atom() | String.t(), map()) :: map()
  defp generic_planner_action(via, name, spec) do
    schema = spec_value(spec, :schema) || %{}
    args = schema_args(schema, spec_aliases(spec))

    %{
      "module" => planner_module_name(via),
      "name" => planner_function_name(name),
      "arity" => length(args),
      "doc" => spec_value(spec, :description) || "",
      "spec" => inspect(schema, limit: 20, printable_limit: 2_000),
      "args" => args,
      "examples" => spec_examples(spec)
    }
  end

  @spec merge_entries(t(), [{map(), target()}]) :: {:ok, t()} | {:error, term()}
  defp merge_entries(catalog, entries) do
    Enum.reduce_while(entries, {:ok, catalog}, &merge_entry/2)
  end

  @spec merge_entry({map(), target()}, {:ok, t()}) ::
          {:cont, {:ok, t()}} | {:halt, {:error, term()}}
  defp merge_entry({action, target}, {:ok, catalog}) do
    id = action["id"]

    if Map.has_key?(catalog.targets, id) do
      {:halt, {:error, {:duplicate_action_provider_tool, id}}}
    else
      case add_exact_examples(catalog.exact_tools, action) do
        {:ok, exact_tools} ->
          {:cont,
           {:ok,
            %{
              catalog
              | actions: [action | catalog.actions],
                targets: Map.put(catalog.targets, id, target),
                exact_tools: exact_tools
            }}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end
  end

  @spec add_exact_examples(map(), map()) :: {:ok, map()} | {:error, term()}
  defp add_exact_examples(exact_tools, action) do
    id = action["id"]

    Enum.reduce_while(List.wrap(action["examples"]), {:ok, exact_tools}, fn example, {:ok, acc} ->
      normalized = normalize_al(example)

      case Map.get(acc, normalized) do
        nil -> {:cont, {:ok, Map.put(acc, normalized, id)}}
        ^id -> {:cont, {:ok, acc}}
        other_id -> {:halt, {:error, {:duplicate_action_provider_example, other_id, id}}}
      end
    end)
  end

  @spec finalize_catalog({:ok, t()} | {:error, term()}) :: {:ok, t()} | {:error, term()}
  defp finalize_catalog({:ok, catalog}),
    do: {:ok, %{catalog | actions: Enum.reverse(catalog.actions)}}

  defp finalize_catalog({:error, _reason} = error), do: error

  @spec runtime_action_map([map()]) :: {:ok, %{String.t() => map()}} | {:error, term()}
  defp runtime_action_map(actions) do
    Enum.reduce_while(actions, {:ok, %{}}, &add_runtime_action/2)
  end

  @spec add_runtime_action(map(), {:ok, %{String.t() => map()}}) ::
          {:cont, {:ok, %{String.t() => map()}}} | {:halt, {:error, term()}}
  defp add_runtime_action(action, {:ok, normalized}) do
    case SpectreKinetic.Planner.Registry.normalize_action(action) do
      {:ok, action} -> add_normalized_runtime_action(action, normalized)
      {:error, reason} -> {:halt, {:error, {:invalid_kinetic_runtime_action, reason}}}
    end
  end

  @spec add_normalized_runtime_action(map(), %{String.t() => map()}) ::
          {:cont, {:ok, %{String.t() => map()}}} | {:halt, {:error, term()}}
  defp add_normalized_runtime_action(action, normalized) do
    id = action["id"]

    if Map.has_key?(normalized, id),
      do: {:halt, {:error, {:duplicate_kinetic_runtime_action, id}}},
      else: {:cont, {:ok, Map.put(normalized, id, action)}}
  end

  @spec schema_args(term(), aliases()) :: [map()]
  defp schema_args(schema, aliases) when is_list(schema),
    do: Enum.map(schema, &normalize_arg(&1, aliases))

  defp schema_args(schema, aliases) when is_map(schema) do
    case Map.get(schema, :args) || Map.get(schema, "args") do
      nil -> json_schema_args(schema, aliases)
      args -> args |> List.wrap() |> Enum.map(&normalize_arg(&1, aliases))
    end
  end

  defp schema_args(_schema, _aliases), do: []

  # Spectre validates a declared action schema against a closed JSON-Schema
  # subset, so slot aliases cannot be carried as an extra schema keyword. They
  # are declared in provider metadata instead, which stays discovery-only data.
  @spec spec_aliases(map()) :: aliases()
  defp spec_aliases(spec) do
    metadata = spec_value(spec, :metadata) || %{}

    metadata
    |> then(&(Map.get(&1, :aliases) || Map.get(&1, "aliases")))
    |> normalize_alias_map()
  end

  @spec normalize_alias_map(term()) :: aliases()
  defp normalize_alias_map(aliases) when is_map(aliases) and not is_struct(aliases) do
    Enum.reduce(aliases, %{}, fn {name, values}, acc ->
      case alias_key(name) do
        nil -> acc
        key -> Map.put(acc, key, alias_list(values))
      end
    end)
  end

  defp normalize_alias_map(aliases) when is_list(aliases) do
    if Keyword.keyword?(aliases),
      do: aliases |> Map.new() |> normalize_alias_map(),
      else: %{}
  end

  defp normalize_alias_map(_aliases), do: %{}

  @spec alias_key(term()) :: String.t() | nil
  defp alias_key(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp alias_key(name) when is_binary(name), do: name
  defp alias_key(_name), do: nil

  # Invalid entries are kept verbatim so registry normalization rejects them
  # with a precise error instead of silently dropping a declared alias.
  @spec alias_list(term()) :: [term()]
  defp alias_list(values) do
    values |> List.wrap() |> Enum.map(&alias_value/1)
  end

  @spec alias_value(term()) :: term()
  defp alias_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp alias_value(value), do: value

  @spec merge_aliases([term()], [term()]) :: [term()]
  defp merge_aliases(declared, extra) do
    Enum.uniq_by(declared ++ extra, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end

  @spec json_schema_args(map(), aliases()) :: [map()]
  defp json_schema_args(schema, aliases) do
    properties = Map.get(schema, :properties) || Map.get(schema, "properties") || %{}
    required = Map.get(schema, :required) || Map.get(schema, "required") || []
    required = MapSet.new(Enum.map(List.wrap(required), &to_string/1))

    json_schema_args(properties, required, aliases)
  end

  @spec json_schema_args(term(), MapSet.t(String.t()), aliases()) :: [map()]
  defp json_schema_args(properties, required, aliases) when is_map(properties) do
    properties
    |> Enum.sort_by(fn {name, _definition} -> to_string(name) end)
    |> Enum.map(&json_schema_arg(&1, required, aliases))
  end

  defp json_schema_args(_properties, _required, _aliases), do: []

  @spec json_schema_arg({term(), term()}, MapSet.t(String.t()), aliases()) :: map()
  defp json_schema_arg({name, definition}, required, aliases) do
    name = to_string(name)
    definition = if is_map(definition), do: definition, else: %{}

    %{
      "name" => name,
      "type" => json_schema_type(definition),
      "required" => MapSet.member?(required, name),
      "aliases" => Map.get(aliases, name, [])
    }
  end

  @spec json_schema_type(map()) :: String.t()
  defp json_schema_type(definition) do
    case Map.get(definition, :type) || Map.get(definition, "type") do
      "array" -> json_schema_array_type(definition)
      types when is_list(types) -> Enum.map_join(types, " | ", &json_primitive_type/1)
      nil -> "term()"
      type -> json_primitive_type(type)
    end
  end

  @spec json_schema_array_type(map()) :: String.t()
  defp json_schema_array_type(definition) do
    items = Map.get(definition, :items) || Map.get(definition, "items") || %{}

    case items do
      items when is_map(items) -> "[#{json_schema_type(items)}]"
      _other -> "list()"
    end
  end

  @spec json_primitive_type(term()) :: String.t()
  defp json_primitive_type("string"), do: "String.t()"
  defp json_primitive_type("integer"), do: "integer()"
  defp json_primitive_type("number"), do: "number()"
  defp json_primitive_type("boolean"), do: "boolean()"
  defp json_primitive_type("object"), do: "map()"
  defp json_primitive_type("array"), do: "list()"
  defp json_primitive_type("null"), do: "nil"
  defp json_primitive_type(type), do: to_string(type)

  @spec normalize_arg(term(), aliases()) :: map()
  defp normalize_arg(arg, aliases) when is_map(arg) do
    name = to_string(Map.get(arg, :name) || Map.get(arg, "name"))

    declared =
      arg
      |> then(&(Map.get(&1, :aliases) || Map.get(&1, "aliases") || []))
      |> alias_list()

    %{
      "name" => name,
      "type" => to_string(Map.get(arg, :type) || Map.get(arg, "type") || "term()"),
      "required" => Map.get(arg, :required, Map.get(arg, "required", true)),
      "aliases" => merge_aliases(declared, Map.get(aliases, name, []))
    }
  end

  defp normalize_arg(name, aliases) when is_atom(name) or is_binary(name) do
    name = to_string(name)

    %{
      "name" => name,
      "type" => "term()",
      "required" => true,
      "aliases" => Map.get(aliases, name, [])
    }
  end

  @spec spec_examples(map()) :: [String.t()]
  defp spec_examples(spec) do
    metadata = spec_value(spec, :metadata) || %{}
    List.wrap(Map.get(metadata, :examples) || Map.get(metadata, "examples") || [])
  end

  @spec planner_module_name(term()) :: String.t()
  defp planner_module_name(via) do
    suffix =
      via
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "Spectre.Provider.P#{suffix}"
  end

  @spec planner_function_name(term()) :: String.t()
  defp planner_function_name(name) when is_atom(name), do: Atom.to_string(name)
  defp planner_function_name(name) when is_binary(name), do: name

  @spec spec_value(map() | nil, atom()) :: term()
  defp spec_value(nil, _key), do: nil

  defp spec_value(spec, key) do
    case Map.fetch(spec, key) do
      {:ok, value} -> value
      :error -> Map.get(spec, Atom.to_string(key))
    end
  end

  @spec plain_map(map()) :: map()
  defp plain_map(%{__struct__: _module} = struct), do: Map.from_struct(struct)
  defp plain_map(map) when is_map(map), do: map

  @spec normalize_al(term()) :: String.t()
  defp normalize_al(al) do
    al
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
