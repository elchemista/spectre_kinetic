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
    function = tool.function
    arity = tool.arity
    params = tool.params
    canonical_al = tool.al
    {doc_text, doc_examples} = split_doc_examples(Map.get(docs, {function, arity}, ""))
    examples = uniq_preserve([canonical_al | doc_examples])
    aliases = aliases_by_param(params, examples)
    spec_entries = Map.get(specs, {function, arity}, [])
    spec_text = spec_text(function, spec_entries)
    arg_types = arg_types(function, spec_entries, length(params))

    action = %{
      "id" => "#{Atom.to_string(module)}.#{function}/#{arity}",
      "module" => Atom.to_string(module),
      "name" => Atom.to_string(function),
      "arity" => arity,
      "doc" => doc_text,
      "spec" => spec_text,
      "args" => build_args(params, arg_types, aliases),
      "examples" => examples
    }

    case Registry.normalize_action(action) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, reason} ->
        {:error, {:invalid_action, module, function, arity, reason}}
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
    indexed_params = Enum.with_index(params)

    param_by_name =
      Map.new(indexed_params, fn {param, index} -> {String.downcase(param), index} end)

    {matched, used_indexes} = exact_slot_matches(slots, param_by_name, params)

    remaining_slots =
      Enum.reject(slots, fn slot ->
        Enum.any?(matched, fn {matched_slot, _param, _index} -> matched_slot == slot end)
      end)

    remaining_params =
      indexed_params
      |> Enum.reject(fn {_param, index} -> MapSet.member?(used_indexes, index) end)

    positional =
      Enum.zip(remaining_slots, remaining_params)
      |> Enum.map(fn {slot, {param, index}} -> {slot, param, index} end)

    (matched ++ positional)
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.map(fn {slot, param, _index} -> {slot, param} end)
  end

  defp exact_slot_matches(slots, param_by_name, params) do
    Enum.reduce(slots, {[], MapSet.new()}, fn slot, {matched, used_indexes} ->
      maybe_add_exact_match(slot, matched, used_indexes, param_by_name, params)
    end)
  end

  defp maybe_add_exact_match(slot, matched, used_indexes, param_by_name, params) do
    case Map.get(param_by_name, String.downcase(slot)) do
      nil ->
        {matched, used_indexes}

      index ->
        if MapSet.member?(used_indexes, index) do
          {matched, used_indexes}
        else
          {[{slot, Enum.at(params, index), index} | matched], MapSet.put(used_indexes, index)}
        end
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
