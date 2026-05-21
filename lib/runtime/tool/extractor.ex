defmodule SpectreKinetic.Tool.Extractor do
  @moduledoc """
  Extracts planner registry actions from compiled Elixir modules using `@al`.
  """

  alias SpectreKinetic.Planner.Registry

  @slot_pattern ~r/(^|[\s,;])([A-Za-z0-9_]+)\s*(?:=|:)\s*(?:"[^"]*"|'[^']*'|\{[^}]*\}|[^\s,;]+)/u

  @type tool_error ::
          {:unknown_app, atom()}
          | {:module_not_loaded, module()}
          | {:invalid_action, module(), atom(), non_neg_integer(), term()}

  @typep tool_identity :: %{
           required(:module) => module(),
           required(:function) => atom(),
           required(:arity) => non_neg_integer(),
           required(:params) => [binary()],
           required(:canonical_al) => binary()
         }

  @typep doc_info :: %{
           required(:text) => binary(),
           required(:examples) => [binary()]
         }

  @typep spec_info :: %{
           required(:text) => binary(),
           required(:arg_types) => [binary()]
         }

  @spec extract_app(atom()) :: {:ok, [Registry.action()]} | {:error, tool_error()}
  def extract_app(app) when is_atom(app) do
    case Application.spec(app, :modules) do
      modules when is_list(modules) -> extract_modules(modules)
      nil -> {:error, {:unknown_app, app}}
    end
  end

  @spec extract_modules([module()]) :: {:ok, [Registry.action()]} | {:error, tool_error()}
  def extract_modules(modules) when is_list(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      case extract_module(module) do
        {:ok, actions} -> {:cont, {:ok, acc ++ actions}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec extract_module(module()) :: {:ok, [Registry.action()]} | {:error, tool_error()}
  def extract_module(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> extract_loaded_module(module)
      _other -> {:error, {:module_not_loaded, module}}
    end
  end

  defp extract_loaded_module(module) do
    if function_exported?(module, :__spectre_tools__, 0) do
      docs = docs_by_function(module)
      specs = specs_by_function(module)
      extract_module_tools(module, docs, specs)
    else
      {:ok, []}
    end
  end

  defp extract_module_tools(module, docs, specs) do
    Enum.reduce_while(module.__spectre_tools__(), {:ok, []}, fn tool, {:ok, acc} ->
      case build_action(module, tool, docs, specs) do
        {:ok, action} -> {:cont, {:ok, [action | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_actions()
  end

  defp build_action(module, tool, docs, specs) do
    identity = tool_identity(module, tool)
    doc_info = action_doc_info(identity, docs)
    spec_info = action_spec_info(identity, specs)

    identity
    |> action_map(doc_info, spec_info)
    |> normalize_built_action(identity)
  end

  @spec tool_identity(module(), map()) :: tool_identity()
  defp tool_identity(module, tool) do
    %{
      module: module,
      function: tool.function,
      arity: tool.arity,
      params: tool.params,
      canonical_al: tool.al
    }
  end

  @spec action_doc_info(tool_identity(), map()) :: doc_info()
  defp action_doc_info(%{function: function, arity: arity, canonical_al: canonical_al}, docs) do
    {text, examples} = split_doc_examples(Map.get(docs, {function, arity}, ""))

    %{
      text: text,
      examples: uniq_preserve([canonical_al | examples])
    }
  end

  @spec action_spec_info(tool_identity(), map()) :: spec_info()
  defp action_spec_info(%{function: function, arity: arity, params: params}, specs) do
    entries = Map.get(specs, {function, arity}, [])

    %{
      text: spec_text(function, entries),
      arg_types: arg_types(function, entries, length(params))
    }
  end

  @spec action_map(tool_identity(), doc_info(), spec_info()) :: map()
  defp action_map(identity, doc_info, spec_info) do
    aliases = aliases_by_param(identity.params, doc_info.examples)

    %{
      "id" => action_id(identity),
      "module" => Atom.to_string(identity.module),
      "name" => Atom.to_string(identity.function),
      "arity" => identity.arity,
      "doc" => doc_info.text,
      "spec" => spec_info.text,
      "args" => build_args(identity.params, spec_info.arg_types, aliases),
      "examples" => doc_info.examples
    }
  end

  @spec action_id(tool_identity()) :: binary()
  defp action_id(%{module: module, function: function, arity: arity}) do
    "#{Atom.to_string(module)}.#{function}/#{arity}"
  end

  @spec normalize_built_action(map(), tool_identity()) ::
          {:ok, Registry.action()} | {:error, tool_error()}
  defp normalize_built_action(action, identity) do
    case Registry.normalize_action(action) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, reason} ->
        {:error, {:invalid_action, identity.module, identity.function, identity.arity, reason}}
    end
  end

  defp docs_by_function(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _lang, _format, _module_doc, _metadata, docs} ->
        Enum.reduce(docs, %{}, fn
          {{:function, name, arity}, _line, _signatures, doc, _metadata}, acc ->
            Map.put(acc, {name, arity}, doc_text(doc))

          _entry, acc ->
            acc
        end)

      _ ->
        %{}
    end
  end

  defp specs_by_function(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} -> Map.new(specs)
      :error -> %{}
    end
  end

  defp doc_text(%{"en" => text}) when is_binary(text), do: text
  defp doc_text(text) when is_binary(text), do: text
  defp doc_text(_), do: ""

  defp split_doc_examples(doc) do
    {clean_lines, examples} =
      doc
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {clean_lines, examples} ->
        trimmed = String.trim(line)

        if String.starts_with?(trimmed, "AL:") do
          example =
            trimmed
            |> String.trim_leading("AL:")
            |> String.trim()

          {clean_lines, examples ++ [example]}
        else
          {clean_lines ++ [line], examples}
        end
      end)

    clean_doc =
      clean_lines
      |> Enum.join("\n")
      |> String.trim()
      |> String.replace(~r/\n{3,}/, "\n\n")

    {clean_doc, examples}
  end

  defp spec_text(_function, []), do: ""

  defp spec_text(function, [spec | _]) do
    function
    |> Code.Typespec.spec_to_quoted(spec)
    |> Macro.to_string()
  rescue
    _error -> ""
  end

  defp arg_types(_function, [], arity), do: List.duplicate("term()", arity)

  defp arg_types(function, [spec | _], arity) do
    function
    |> Code.Typespec.spec_to_quoted(spec)
    |> extract_spec_args(function)
    |> case do
      nil -> List.duplicate("term()", arity)
      args -> Enum.map(args, &arg_type_string/1)
    end
  rescue
    _error -> List.duplicate("term()", arity)
  end

  defp extract_spec_args({:"::", _, [{name, _, args}, _return]}, name), do: List.wrap(args)

  defp extract_spec_args({:when, _, [{:"::", _, [{name, _, args}, _return]}, _guards]}, name),
    do: List.wrap(args)

  defp extract_spec_args(_quoted, _name), do: nil

  defp arg_type_string({:"::", _, [_var, type_ast]}), do: Macro.to_string(type_ast)
  defp arg_type_string(type_ast), do: Macro.to_string(type_ast)

  defp build_args(params, arg_types, aliases) do
    params
    |> Enum.with_index()
    |> Enum.map(fn {param, index} ->
      %{
        "name" => param,
        "type" => Enum.at(arg_types, index) || "term()",
        "required" => true,
        "aliases" => Map.get(aliases, param, [])
      }
    end)
  end

  defp aliases_by_param(params, examples) do
    Enum.reduce(examples, Map.new(params, &{&1, []}), fn example, alias_map ->
      example
      |> slot_keys()
      |> map_slots_to_params(params)
      |> merge_slot_aliases(alias_map)
    end)
  end

  defp map_slots_to_params(slots, params) do
    indexed_params = indexed_params(params)

    {exact_matches, used_indexes} =
      exact_slot_matches(slots, param_index_by_name(indexed_params), params)

    positional_matches =
      positional_slot_matches(slots, indexed_params, exact_matches, used_indexes)

    exact_matches
    |> Kernel.++(positional_matches)
    |> ordered_slot_param_pairs()
  end

  @spec indexed_params([binary()]) :: [{binary(), non_neg_integer()}]
  defp indexed_params(params), do: Enum.with_index(params)

  @spec param_index_by_name([{binary(), non_neg_integer()}]) :: map()
  defp param_index_by_name(indexed_params) do
    Map.new(indexed_params, fn {param, index} -> {String.downcase(param), index} end)
  end

  @spec positional_slot_matches(
          [binary()],
          [{binary(), non_neg_integer()}],
          [{binary(), binary(), non_neg_integer()}],
          MapSet.t(non_neg_integer())
        ) :: [{binary(), binary(), non_neg_integer()}]
  defp positional_slot_matches(slots, indexed_params, exact_matches, used_indexes) do
    slots
    |> unmatched_slots(exact_matches)
    |> Enum.zip(unused_params(indexed_params, used_indexes))
    |> Enum.map(fn {slot, {param, index}} -> {slot, param, index} end)
  end

  @spec unmatched_slots([binary()], [{binary(), binary(), non_neg_integer()}]) :: [binary()]
  defp unmatched_slots(slots, exact_matches) do
    matched_slots = MapSet.new(exact_matches, fn {slot, _param, _index} -> slot end)
    Enum.reject(slots, &MapSet.member?(matched_slots, &1))
  end

  @spec unused_params([{binary(), non_neg_integer()}], MapSet.t(non_neg_integer())) ::
          [{binary(), non_neg_integer()}]
  defp unused_params(indexed_params, used_indexes) do
    Enum.reject(indexed_params, fn {_param, index} -> MapSet.member?(used_indexes, index) end)
  end

  @spec ordered_slot_param_pairs([{binary(), binary(), non_neg_integer()}]) ::
          [{binary(), binary()}]
  defp ordered_slot_param_pairs(matches) do
    matches
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.map(fn {slot, param, _index} -> {slot, param} end)
  end

  @spec exact_slot_matches([binary()], map(), [binary()]) ::
          {[{binary(), binary(), non_neg_integer()}], MapSet.t(non_neg_integer())}
  defp exact_slot_matches(slots, param_by_name, params) do
    Enum.reduce(slots, {[], MapSet.new()}, fn slot, {matched, used_indexes} ->
      maybe_add_exact_match(slot, matched, used_indexes, param_by_name, params)
    end)
  end

  @spec maybe_add_exact_match(
          binary(),
          [{binary(), binary(), non_neg_integer()}],
          MapSet.t(non_neg_integer()),
          map(),
          [binary()]
        ) :: {[{binary(), binary(), non_neg_integer()}], MapSet.t(non_neg_integer())}
  defp maybe_add_exact_match(slot, matched, used_indexes, param_by_name, params) do
    case exact_param_index(slot, param_by_name) do
      {:ok, index} ->
        add_exact_match(slot, index, matched, used_indexes, params)

      :error ->
        {matched, used_indexes}
    end
  end

  @spec add_exact_match(
          binary(),
          non_neg_integer(),
          [{binary(), binary(), non_neg_integer()}],
          MapSet.t(non_neg_integer()),
          [binary()]
        ) :: {[{binary(), binary(), non_neg_integer()}], MapSet.t(non_neg_integer())}
  defp add_exact_match(slot, index, matched, used_indexes, params) do
    if MapSet.member?(used_indexes, index) do
      {matched, used_indexes}
    else
      {[{slot, Enum.at(params, index), index} | matched], MapSet.put(used_indexes, index)}
    end
  end

  @spec exact_param_index(binary(), map()) :: {:ok, non_neg_integer()} | :error
  defp exact_param_index(slot, param_by_name) do
    case Map.fetch(param_by_name, String.downcase(slot)) do
      {:ok, index} -> {:ok, index}
      :error -> :error
    end
  end

  defp merge_slot_aliases(slot_param_pairs, alias_map) do
    Enum.reduce(slot_param_pairs, alias_map, fn {slot, param}, acc ->
      update_alias_map(acc, slot, param)
    end)
  end

  defp update_alias_map(alias_map, slot, param) do
    if String.downcase(slot) == String.downcase(param) do
      alias_map
    else
      Map.update!(alias_map, param, &uniq_preserve([slot | &1]))
    end
  end

  defp reverse_actions({:ok, actions}), do: {:ok, Enum.reverse(actions)}
  defp reverse_actions(other), do: other

  defp slot_keys(example) do
    Regex.scan(@slot_pattern, example, capture: :all_but_first)
    |> Enum.map(fn [_boundary, key] -> key end)
  end

  defp uniq_preserve(values) do
    values
    |> Enum.reduce({MapSet.new(), []}, fn value, {seen, acc} ->
      if MapSet.member?(seen, value) do
        {seen, acc}
      else
        {MapSet.put(seen, value), [value | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
