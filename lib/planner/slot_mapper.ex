defmodule SpectreKinetic.Planner.SlotMapper do
  @moduledoc """
  Deterministic slot-to-parameter mapping for the Elixir planner.

  Resolves AL arguments (slots) to tool parameters using:

  1. Exact name match (case-insensitive)
  2. Alias match from the tool's arg definition
  3. Value-shape/type priors (email, phone, URL, date, boolean, number)
  4. Positional fallback for single remaining unmatched slots

  This module does not use embeddings — mapping is fully deterministic
  and schema-aware.
  """

  @type mapping_result :: %{
          args: map(),
          invalid: [map()],
          missing: [binary()],
          notes: [binary()],
          mapping_score: float()
        }

  alias SpectreKinetic.Planner.SlotType

  @email_pattern ~r/^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$/
  @phone_pattern ~r/^\+?[0-9\s\-().]{7,}$/
  @url_pattern ~r/^https?:\/\//i
  @date_pattern ~r/^\d{4}-\d{2}-\d{2}/
  @time_pattern ~r/^\d{1,2}:\d{2}/
  @boolean_values ~w(true false yes no on off 1 0)
  @integer_pattern ~r/^-?\d+$/
  @float_pattern ~r/^-?\d+\.\d+$/
  @path_pattern ~r/^[\/~.][\w\/.\-]+$/
  @positional_score_cap 0.5

  # Type hints: maps value-shape types to likely parameter names
  @type_hints %{
    :email => ~w(to email recipient cc bcc reply_to from sender),
    :phone => ~w(to phone number recipient mobile cell),
    :url => ~w(url uri link website href endpoint),
    :date => ~w(due date deadline start_date end_date created_at updated_at),
    :time => ~w(time at scheduled_at),
    :path => ~w(path file source dest destination target dir directory location),
    :boolean => ~w(enabled active force draft published confirmed),
    :integer => ~w(id count limit offset port priority arity),
    :float => ~w(amount price rate score threshold confidence)
  }

  @doc """
  Maps parsed AL slots to tool parameters for a given action definition.

  Returns a mapping result with resolved args, missing required params,
  notes, and a mapping quality score.
  """
  @spec map_slots(map(), map()) :: mapping_result()
  def map_slots(parsed_args, action) do
    arg_defs = action["args"] || []
    slots = normalize_slot_keys(parsed_args)

    {matched, unmatched_slots, unmatched_params} =
      resolve_all(slots, arg_defs)

    {type_matched, still_unmatched_slots, still_unmatched_params} =
      resolve_by_type(unmatched_slots, unmatched_params)

    {positional, final_unmatched_slots, final_unmatched_params} =
      resolve_positional(still_unmatched_slots, still_unmatched_params)

    all_matched = Map.merge(matched, type_matched) |> Map.merge(positional)
    {valid_args, invalid} = validate_mapped_args(all_matched, arg_defs)

    missing =
      (final_unmatched_params ++ invalid_required_params(invalid, arg_defs))
      |> Enum.filter(& &1["required"])
      |> Enum.map(& &1["name"])
      |> Enum.uniq()

    notes =
      build_notes(final_unmatched_slots, missing) ++
        positional_notes(positional) ++ invalid_notes(invalid)

    score =
      arg_defs
      |> compute_mapping_score(valid_args, missing)
      |> cap_positional_score(positional)

    %{
      args: valid_args,
      invalid: invalid,
      missing: missing,
      notes: notes,
      mapping_score: score
    }
  end

  defp validate_mapped_args(matched, arg_defs) do
    definitions = Map.new(arg_defs, &{&1["name"], &1})

    matched
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, []}, fn {name, value}, {valid, invalid} ->
      definition = Map.fetch!(definitions, name)
      expected_type = definition["type"] || "String.t()"

      case SlotType.coerce(value, expected_type) do
        {:ok, coerced} ->
          {Map.put(valid, name, coerced), invalid}

        {:error, reason} ->
          issue = %{name: name, expected_type: expected_type, reason: reason}
          {valid, [issue | invalid]}
      end
    end)
    |> then(fn {valid, invalid} -> {valid, Enum.reverse(invalid)} end)
  end

  defp invalid_required_params(invalid, arg_defs) do
    invalid_names = invalid |> Enum.map(& &1.name) |> MapSet.new()
    Enum.filter(arg_defs, &MapSet.member?(invalid_names, &1["name"]))
  end

  defp invalid_notes(invalid) do
    Enum.map(invalid, fn issue ->
      "invalid type for #{issue.name}: expected #{issue.expected_type} (#{format_reason(issue.reason)})"
    end)
  end

  defp format_reason(:type_mismatch), do: "type mismatch"
  defp format_reason({:unsupported_type, type}), do: "unsupported type #{type}"

  # Three passes: names first, then value shape, then the one lonely positional
  # fallback. More magic here would make the planner look smart and age badly.
  # Stage 1: Exact name and alias matching
  defp resolve_all(slots, arg_defs) do
    {matched, remaining_slots, remaining_params} =
      Enum.reduce(arg_defs, {%{}, slots, []}, fn arg_def, {matched, slots_left, unresolved} ->
        canonical = arg_def["name"]
        aliases = [canonical | arg_def["aliases"] || []]
        lower_aliases = Enum.map(aliases, &String.downcase/1)

        case find_slot(slots_left, lower_aliases) do
          {slot_key, value} ->
            {
              Map.put(matched, canonical, value),
              Map.delete(slots_left, slot_key),
              unresolved
            }

          nil ->
            {matched, slots_left, [arg_def | unresolved]}
        end
      end)

    {matched, remaining_slots, Enum.reverse(remaining_params)}
  end

  # Stage 2: Type-shape inference
  defp resolve_by_type(slots, params) when map_size(slots) == 0 or params == [] do
    {%{}, slots, params}
  end

  defp resolve_by_type(slots, params) do
    Enum.reduce(Map.to_list(slots), {%{}, slots, params}, fn {slot_key, value},
                                                             {matched, slots_left, params_left} ->
      case infer_type_match(value, params_left) do
        {:ok, param_def} ->
          {
            Map.put(matched, param_def["name"], value),
            Map.delete(slots_left, slot_key),
            List.delete(params_left, param_def)
          }

        :no_match ->
          {matched, slots_left, params_left}
      end
    end)
  end

  # Stage 3: Positional assignment for single remaining pairs
  defp resolve_positional(slots, params) when map_size(slots) == 0 or params == [] do
    {%{}, slots, params}
  end

  defp resolve_positional(slots, [single_param]) when map_size(slots) == 1 do
    [{slot_key, value}] = Map.to_list(slots)
    {%{single_param["name"] => value}, Map.delete(slots, slot_key), []}
  end

  defp resolve_positional(slots, params) do
    {%{}, slots, params}
  end

  # Type guesses are hints, not authority. The registry schema still gets the
  # last word, because production prefers boring adults in the room.
  defp infer_type_match(value, params) do
    case detect_value_type(value) do
      nil -> :no_match
      type -> match_param_for_type(params, type)
    end
  end

  @doc """
  Detects the value shape/type of a string value.
  """
  @spec detect_value_type(binary()) :: atom() | nil
  def detect_value_type(value) when is_binary(value) do
    case detect_textual_type(value) do
      nil -> detect_scalar_type(value)
      type -> type
    end
  end

  def detect_value_type(_), do: nil

  defp normalize_slot_keys(parsed_args) do
    Map.new(parsed_args, fn {key, value} -> {String.downcase(key), value} end)
  end

  defp find_slot(slots, lower_aliases) do
    Enum.find_value(lower_aliases, fn alias_name ->
      case Map.fetch(slots, alias_name) do
        {:ok, value} -> {alias_name, value}
        :error -> nil
      end
    end)
  end

  defp build_notes(unmatched_slots, _missing) do
    case Map.keys(unmatched_slots) do
      [] -> []
      keys -> ["unmatched slots: #{inspect(keys)}"]
    end
  end

  defp positional_notes(positional) when map_size(positional) > 0,
    do: ["low-confidence positional slot mapping"]

  defp positional_notes(_positional), do: []

  defp cap_positional_score(score, positional) when map_size(positional) > 0,
    do: min(score, @positional_score_cap)

  defp cap_positional_score(score, _positional), do: score

  defp compute_mapping_score(arg_defs, matched, missing) do
    n_total = length(arg_defs)
    n_required = Enum.count(arg_defs, & &1["required"])
    n_matched = map_size(matched)
    n_missing = length(missing)

    cond do
      n_total == 0 -> 1.0
      n_missing == 0 -> min(1.0, n_matched / max(n_required, 1))
      true -> max(0.0, (n_required - n_missing) / max(n_required, 1))
    end
  end

  defp match_param_for_type(params, type) do
    match = Enum.find(params, &(String.downcase(&1["name"]) in Map.get(@type_hints, type, [])))

    case match do
      nil -> :no_match
      param -> {:ok, param}
    end
  end

  defp detect_textual_type(value) do
    cond do
      Regex.match?(@email_pattern, value) -> :email
      Regex.match?(@url_pattern, value) -> :url
      Regex.match?(@date_pattern, value) -> :date
      Regex.match?(@time_pattern, value) -> :time
      Regex.match?(@phone_pattern, value) -> :phone
      Regex.match?(@path_pattern, value) -> :path
      true -> nil
    end
  end

  defp detect_scalar_type(value) do
    normalized = String.downcase(value)

    cond do
      normalized in @boolean_values -> :boolean
      Regex.match?(@float_pattern, value) -> :float
      Regex.match?(@integer_pattern, value) -> :integer
      true -> nil
    end
  end
end
