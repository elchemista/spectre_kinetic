defmodule SpectreKinetic.Planner.Registry do
  @moduledoc """
  Planner-facing registry behavior plus shared action normalization helpers.

  The planner depends on this behavior instead of directly depending on ETS so
  alternate backends can provide the same registry operations.

  Registry adapters own storage and lookup mechanics. The planner owns ranking
  and mapping. This behaviour keeps that dependency direction explicit:

  - runtime code may call any module that implements this behaviour
  - registry implementations can be ETS, compiled files, test doubles, or a
    future persistent backend
  - shared normalization stays here so every backend receives the same action
    shape

  A backend also declares who owns mutations through `owner/1`. `:shared`
  backends may be mutated by any caller. Process-owned backends return their
  owner pid and must reject mutations and closure from other processes. Reads
  may remain shareable when the storage implementation permits it.

  ## Canonical action shape

      %{
        "id" => "Mail.send/2",
        "module" => "Mail",
        "name" => "send",
        "arity" => 2,
        "doc" => "Sends one email.",
        "spec" => "send(to :: String.t(), subject :: String.t()) :: :ok",
        "args" => [
          %{"name" => "to", "type" => "String.t()", "required" => true, "aliases" => []}
        ],
        "examples" => ["SEND EMAIL WITH: TO=dev@example.com"]
      }
  """

  @type action :: map()
  @type embedding_matrix :: {Nx.Tensor.t(), [binary()]}

  @max_args 128
  @max_aliases 64
  @max_examples 64
  @string_byte_limits %{
    "module" => 512,
    "name" => 256,
    "id" => 1_024,
    "doc" => 64 * 1_024,
    "spec" => 64 * 1_024,
    "type" => 1_024,
    "aliases" => 256,
    "examples" => 8 * 1_024
  }

  @callback new(keyword()) :: {:ok, term()} | {:error, term()}
  @callback owner(term()) :: pid() | :shared
  @callback new_staging(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback load_json(term(), binary()) :: {:ok, term()} | {:error, term()}
  @callback load_compiled(term(), binary()) :: {:ok, term()} | {:error, term()}
  @callback all_actions(term()) :: [action()]
  @callback get_action(term(), binary()) :: action() | nil
  @callback action_count(term()) :: non_neg_integer()
  @callback add_action(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback upsert_action(term(), map(), Nx.Tensor.t() | nil) ::
              {:ok, term()} | {:error, term()}
  @callback delete_action(term(), binary()) :: {{:ok, boolean()}, term()} | {:error, term()}
  @callback embedding_matrix(term()) :: embedding_matrix() | nil
  @callback put_embedding(term(), binary(), Nx.Tensor.t()) :: {:ok, term()} | {:error, term()}
  @callback tool_cards(term()) :: [{binary(), binary()}]
  @callback resolve_alias(term(), binary()) :: [{binary(), binary()}]
  @callback close(term()) :: :ok | {:error, term()}

  @optional_callbacks owner: 1, new_staging: 2, upsert_action: 3

  @doc false
  @spec mutation_owner(module(), term()) :: pid() | :shared
  def mutation_owner(registry_module, registry) do
    if function_exported?(registry_module, :owner, 1) do
      registry_module.owner(registry)
    else
      :shared
    end
  end

  @doc false
  @spec stage(module(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def stage(registry_module, active_registry, opts) do
    if not is_nil(active_registry) and
         function_exported?(registry_module, :new_staging, 2) do
      registry_module.new_staging(active_registry, opts)
    else
      registry_module.new([])
    end
  end

  @doc false
  @spec upsert(module(), term(), map(), Nx.Tensor.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def upsert(registry_module, registry, action, embedding) do
    cond do
      function_exported?(registry_module, :upsert_action, 3) ->
        registry_module.upsert_action(registry, action, embedding)

      is_nil(embedding) ->
        registry_module.add_action(registry, action)

      true ->
        {:error, {:unsupported_registry_operation, :atomic_upsert_with_embedding}}
    end
  end

  @doc """
  Normalizes one raw registry action into the planner's canonical action shape.

  Input may use atom or string keys because actions can come from Elixir code,
  JSON, or ETF bundles. Normalization converts keys to strings and fills in
  harmless defaults so downstream scoring code can be small and predictable.

  ## Examples

      iex> {:ok, action} =
      ...>   SpectreKinetic.Planner.Registry.normalize_action(%{
      ...>     module: "Mail",
      ...>     name: "send",
      ...>     arity: 1,
      ...>     args: [%{name: "to"}]
      ...>   })
      iex> action["id"]
      "Mail.send/1"
      iex> action["args"]
      [%{"name" => "to", "type" => "String.t()", "required" => true, "aliases" => []}]

      iex> SpectreKinetic.Planner.Registry.normalize_action(%{})
      {:error, {:invalid_field, "module", :must_be_string}}
  """
  @spec normalize_action(map()) :: {:ok, action()} | {:error, term()}
  def normalize_action(raw) when is_map(raw) do
    try do
      raw
      |> stringify_map()
      |> do_normalize_action()
    rescue
      _error -> {:error, :invalid_action}
    catch
      _kind, _reason -> {:error, :invalid_action}
    end
  end

  def normalize_action(_raw), do: {:error, :invalid_action}

  defp do_normalize_action(raw) do
    with {:ok, module_name} <- required_string(raw, "module"),
         {:ok, function_name} <- required_string(raw, "name"),
         {:ok, arity} <- non_negative_integer(raw, "arity"),
         {:ok, args} <- normalize_args(Map.get(raw, "args", [])),
         :ok <- validate_arity(arity, args),
         :ok <- validate_arg_names(args),
         {:ok, id} <- action_id(raw["id"], module_name, function_name, arity),
         {:ok, doc} <- optional_string(raw, "doc"),
         {:ok, spec} <- optional_string(raw, "spec"),
         {:ok, examples} <- normalize_examples(Map.get(raw, "examples", [])) do
      {:ok,
       %{
         "id" => id,
         "module" => module_name,
         "name" => function_name,
         "arity" => arity,
         "doc" => doc,
         "spec" => spec,
         "args" => args,
         "examples" => examples
       }}
    end
  end

  @doc """
  Builds a compact retrieval card from one normalized action definition.

  Retrieval cards are intentionally plain text. Embedding models and lexical
  scoring both work better when the card contains the searchable facts a human
  would use: module/function, docs, argument names, and a few examples.

  ## Example

      iex> SpectreKinetic.Planner.Registry.build_tool_card(%{
      ...>   "module" => "Mail",
      ...>   "name" => "send",
      ...>   "doc" => "Sends one email.",
      ...>   "args" => [%{"name" => "to"}],
      ...>   "examples" => ["SEND EMAIL WITH: TO=dev@example.com"]
      ...> })
      "Mail.send - Sends one email. - args: to - examples: SEND EMAIL WITH: TO=dev@example.com"
  """
  @spec build_tool_card(action()) :: binary()
  def build_tool_card(action) do
    name_part = action["name"] || ""
    module_part = action["module"] || ""
    doc_part = action["doc"] || ""

    arg_names =
      action["args"]
      |> List.wrap()
      |> Enum.map(& &1["name"])
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    examples =
      action["examples"]
      |> List.wrap()
      |> Enum.take(3)
      |> Enum.join(" | ")

    [
      "#{module_part}.#{name_part}",
      doc_part,
      if(arg_names != "", do: "args: #{arg_names}"),
      if(examples != "", do: "examples: #{examples}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" - ")
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> non_blank_string(value, key)
      _value -> {:error, {:invalid_field, key, :must_be_string}}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key, "") do
      value when is_binary(value) -> valid_string(value, key)
      _value -> {:error, {:invalid_field, key, :must_be_string}}
    end
  end

  defp non_blank_string(value, key) do
    with {:ok, value} <- valid_string(value, key) do
      if String.trim(value) == "" do
        {:error, {:invalid_field, key, :must_not_be_blank}}
      else
        {:ok, value}
      end
    end
  end

  defp valid_string(value, key) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_field, key, :must_be_utf8}}

      byte_size(value) > Map.get(@string_byte_limits, key, 1_024) ->
        {:error, {:invalid_field, key, :exceeds_size_limit}}

      true ->
        {:ok, value}
    end
  end

  defp non_negative_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_field, key, :must_be_non_negative_integer}}
    end
  end

  defp action_id(nil, module_name, function_name, arity),
    do: {:ok, "#{module_name}.#{function_name}/#{arity}"}

  defp action_id(id, module_name, function_name, arity) when is_binary(id) do
    expected = "#{module_name}.#{function_name}/#{arity}"

    with {:ok, id} <- non_blank_string(id, "id") do
      if id == expected do
        {:ok, id}
      else
        {:error, {:invalid_field, "id", {:mfa_mismatch, expected}}}
      end
    end
  end

  defp action_id(_id, _module_name, _function_name, _arity),
    do: {:error, {:invalid_field, "id", :must_be_string}}

  @spec normalize_args(term()) :: {:ok, [map()]} | {:error, term()}
  defp normalize_args(args) when is_list(args) do
    if list_exceeds_limit?(args, @max_args) do
      {:error, {:invalid_field, "args", :too_many_entries}}
    else
      normalize_arg_list(args)
    end
  end

  defp normalize_args(_args), do: {:error, {:invalid_field, "args", :must_be_list}}

  @spec normalize_arg_list([term()]) :: {:ok, [map()]} | {:error, term()}
  defp normalize_arg_list(args) do
    args
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {arg, index}, {:ok, normalized} ->
      case normalize_arg(arg, index) do
        {:ok, next} -> {:cont, {:ok, [next | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_normalized_list()
  end

  @spec reverse_normalized_list({:ok, [term()]} | {:error, term()}) ::
          {:ok, [term()]} | {:error, term()}
  defp reverse_normalized_list({:ok, normalized}), do: {:ok, Enum.reverse(normalized)}
  defp reverse_normalized_list({:error, _reason} = error), do: error

  defp normalize_arg(arg, index) when is_map(arg) do
    arg = stringify_map(arg)

    with {:ok, name} <- required_string(arg, "name"),
         {:ok, type} <- arg_type(arg),
         {:ok, required} <- required_flag(arg),
         {:ok, aliases} <- normalize_aliases(Map.get(arg, "aliases", []), index) do
      {:ok,
       %{
         "name" => name,
         "type" => type,
         "required" => required,
         "aliases" => aliases
       }}
    else
      {:error, reason} -> {:error, {:invalid_arg, index, reason}}
    end
  end

  defp normalize_arg(_arg, index),
    do: {:error, {:invalid_arg, index, :must_be_map}}

  defp arg_type(arg) do
    case Map.get(arg, "type", "String.t()") do
      type when is_binary(type) -> non_blank_string(type, "type")
      _type -> {:error, {:invalid_field, "type", :must_be_string}}
    end
  end

  defp required_flag(arg) do
    case Map.get(arg, "required", true) do
      required when is_boolean(required) -> {:ok, required}
      _required -> {:error, {:invalid_field, "required", :must_be_boolean}}
    end
  end

  @spec normalize_aliases(term(), non_neg_integer()) :: {:ok, [binary()]} | {:error, term()}
  defp normalize_aliases(aliases, index) when is_list(aliases) do
    if list_exceeds_limit?(aliases, @max_aliases) do
      {:error, {:invalid_field, "aliases", :too_many_entries}}
    else
      case normalize_non_blank_strings(aliases, "aliases", :must_contain_strings) do
        {:ok, normalized} -> validate_alias_duplicates(normalized, index)
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize_aliases(_aliases, _index),
    do: {:error, {:invalid_field, "aliases", :must_be_list}}

  @spec normalize_non_blank_strings([term()], binary(), atom()) ::
          {:ok, [binary()]} | {:error, term()}
  defp normalize_non_blank_strings(values, field, non_binary_reason) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case normalize_non_blank_string(value, field, non_binary_reason) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_normalized_list()
  end

  @spec normalize_non_blank_string(term(), binary(), atom()) ::
          {:ok, binary()} | {:error, term()}
  defp normalize_non_blank_string(value, field, _non_binary_reason) when is_binary(value),
    do: non_blank_string(value, field)

  defp normalize_non_blank_string(_value, field, non_binary_reason),
    do: {:error, {:invalid_field, field, non_binary_reason}}

  defp validate_alias_duplicates(aliases, index) do
    normalized = Enum.map(aliases, &String.downcase/1)

    if length(normalized) == length(Enum.uniq(normalized)) do
      {:ok, aliases}
    else
      {:error, {:duplicate_alias, index}}
    end
  end

  defp validate_arity(arity, args) do
    if arity == length(args) do
      :ok
    else
      {:error, {:arity_mismatch, arity, length(args)}}
    end
  end

  defp validate_arg_names(args) do
    args
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {arg, index}, {:ok, seen} ->
      names = [arg["name"] | arg["aliases"]]

      case {duplicate_name(names), conflicting_name(names, seen)} do
        {{name, _first_index, _duplicate_index}, _conflict} ->
          {:halt, {:error, {:ambiguous_arg_name, name, index, index}}}

        {nil, nil} ->
          next_seen = Enum.reduce(names, seen, &Map.put(&2, String.downcase(&1), index))
          {:cont, {:ok, next_seen}}

        {nil, {name, previous_index}} ->
          {:halt, {:error, {:ambiguous_arg_name, name, previous_index, index}}}
      end
    end)
    |> then(fn
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end)
  end

  defp duplicate_name(names) do
    names
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {name, index}, seen ->
      key = String.downcase(name)

      case Map.fetch(seen, key) do
        {:ok, first_index} -> {:halt, {name, first_index, index}}
        :error -> {:cont, Map.put(seen, key, index)}
      end
    end)
    |> case do
      result when is_map(result) -> nil
      duplicate -> duplicate
    end
  end

  defp conflicting_name(names, seen) do
    Enum.find_value(names, fn name ->
      key = String.downcase(name)
      if Map.has_key?(seen, key), do: {name, Map.fetch!(seen, key)}
    end)
  end

  @spec normalize_examples(term()) :: {:ok, [binary()]} | {:error, term()}
  defp normalize_examples(examples) when is_list(examples) do
    if list_exceeds_limit?(examples, @max_examples) do
      {:error, {:invalid_field, "examples", :too_many_entries}}
    else
      normalize_non_blank_strings(
        examples,
        "examples",
        :must_contain_non_blank_strings
      )
    end
  end

  defp normalize_examples(_examples),
    do: {:error, {:invalid_field, "examples", :must_be_list}}

  defp list_exceeds_limit?([], _remaining), do: false
  defp list_exceeds_limit?([_head | _tail], 0), do: true

  defp list_exceeds_limit?([_head | tail], remaining),
    do: list_exceeds_limit?(tail, remaining - 1)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
