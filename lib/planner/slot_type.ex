defmodule SpectreKinetic.Planner.SlotType do
  @moduledoc false

  @true_values ~w(true yes on 1)
  @false_values ~w(false no off 0)

  @type coercion_error :: :type_mismatch | {:unsupported_type, binary()}

  @spec coerce(term(), term()) :: {:ok, term()} | {:error, coercion_error()}
  def coerce(value, type) when is_binary(type) do
    type
    |> String.split(~r/\s*\|\s*/, trim: true)
    |> coerce_union(value, nil)
  end

  def coerce(_value, type), do: {:error, {:unsupported_type, inspect(type)}}

  defp coerce_union([], _value, nil), do: {:error, :type_mismatch}
  defp coerce_union([], _value, unsupported), do: {:error, unsupported}

  defp coerce_union([type | rest], value, unsupported) do
    case coerce_one(value, normalize_type(type)) do
      {:ok, _coerced} = ok -> ok
      {:error, :type_mismatch} -> coerce_union(rest, value, unsupported)
      {:error, {:unsupported_type, _type} = error} -> coerce_union(rest, value, error)
    end
  end

  defp normalize_type(type) do
    type
    |> String.trim()
    |> String.replace(" ", "")
  end

  defp coerce_one(nil, type) when type in ["nil", "nil()"], do: {:ok, nil}

  defp coerce_one(value, type) when type in ["String.t()", "binary()", "binary"] do
    if is_binary(value), do: {:ok, value}, else: {:error, :type_mismatch}
  end

  defp coerce_one(value, type) when type in ["integer()", "integer"] do
    coerce_integer(value, fn _integer -> true end)
  end

  defp coerce_one(value, type) when type in ["non_neg_integer()", "non_neg_integer"] do
    coerce_integer(value, &(&1 >= 0))
  end

  defp coerce_one(value, type) when type in ["pos_integer()", "pos_integer"] do
    coerce_integer(value, &(&1 > 0))
  end

  defp coerce_one(value, type) when type in ["float()", "float"] do
    coerce_float(value)
  end

  defp coerce_one(value, type) when type in ["number()", "number"] do
    case coerce_integer(value, fn _integer -> true end) do
      {:ok, integer} -> {:ok, integer}
      {:error, :type_mismatch} -> coerce_float(value)
    end
  end

  defp coerce_one(value, type) when type in ["boolean()", "boolean"] do
    coerce_boolean(value)
  end

  defp coerce_one(value, type) when type in ["Date.t()", "Date"] do
    validate_iso_date(value)
  end

  defp coerce_one(value, type) when type in ["DateTime.t()", "DateTime"] do
    validate_iso_datetime(value)
  end

  defp coerce_one(value, type) when type in ["URI.t()", "URI"] do
    validate_uri(value)
  end

  defp coerce_one(value, type) when type in ["map()", "map"] do
    if is_map(value) and not is_struct(value),
      do: {:ok, value},
      else: {:error, :type_mismatch}
  end

  defp coerce_one(value, type) when type in ["list()", "list"] do
    if is_list(value), do: {:ok, value}, else: {:error, :type_mismatch}
  end

  defp coerce_one(value, <<"[", rest::binary>> = type) do
    if String.ends_with?(rest, "]") do
      inner_size = byte_size(rest) - 1
      inner_type = binary_part(rest, 0, inner_size)
      coerce_list(value, inner_type)
    else
      {:error, {:unsupported_type, type}}
    end
  end

  defp coerce_one(value, <<"list(", rest::binary>> = type) do
    if String.ends_with?(rest, ")") do
      inner_size = byte_size(rest) - 1
      inner_type = binary_part(rest, 0, inner_size)
      coerce_list(value, inner_type)
    else
      {:error, {:unsupported_type, type}}
    end
  end

  defp coerce_one(value, type) when type in ["atom()", "atom"] do
    if is_atom(value), do: {:ok, value}, else: {:error, :type_mismatch}
  end

  defp coerce_one(value, type) when type in ["term()", "any()", "any"], do: {:ok, value}

  defp coerce_one(value, <<":", literal::binary>>) when literal != "" do
    case value do
      ^literal -> {:ok, value}
      atom when is_atom(atom) -> literal_atom_value(atom, literal)
      _other -> {:error, :type_mismatch}
    end
  end

  defp coerce_one(value, "true") when value in [true, "true"], do: {:ok, true}
  defp coerce_one(value, "false") when value in [false, "false"], do: {:ok, false}

  # Domain-specific types need an explicit coercer in a future registry schema.
  # Accepting them blindly would make the type gate decorative.
  defp coerce_one(_value, unknown_type), do: {:error, {:unsupported_type, unknown_type}}

  defp coerce_list(value, inner_type) when is_list(value) and inner_type != "" do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, coerced} ->
      case coerce(item, inner_type) do
        {:ok, next} -> {:cont, {:ok, [next | coerced]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, coerced} -> {:ok, Enum.reverse(coerced)}
      {:error, _reason} = error -> error
    end)
  end

  defp coerce_list(_value, _inner_type), do: {:error, :type_mismatch}

  defp literal_atom_value(atom, literal) do
    if Atom.to_string(atom) == literal,
      do: {:ok, atom},
      else: {:error, :type_mismatch}
  end

  defp coerce_integer(value, predicate) when is_integer(value) do
    if predicate.(value), do: {:ok, value}, else: {:error, :type_mismatch}
  end

  defp coerce_integer(value, predicate) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> coerce_integer(integer, predicate)
      _invalid -> {:error, :type_mismatch}
    end
  end

  defp coerce_integer(_value, _predicate), do: {:error, :type_mismatch}

  defp coerce_float(value) when is_float(value), do: {:ok, value}
  defp coerce_float(value) when is_integer(value), do: {:ok, value * 1.0}

  defp coerce_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _invalid -> {:error, :type_mismatch}
    end
  end

  defp coerce_float(_value), do: {:error, :type_mismatch}

  defp coerce_boolean(value) when is_boolean(value), do: {:ok, value}

  defp coerce_boolean(value) when is_binary(value) do
    normalized = String.downcase(value)

    cond do
      normalized in @true_values -> {:ok, true}
      normalized in @false_values -> {:ok, false}
      true -> {:error, :type_mismatch}
    end
  end

  defp coerce_boolean(_value), do: {:error, :type_mismatch}

  defp validate_iso_date(%Date{} = value), do: {:ok, value}

  defp validate_iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> {:ok, value}
      {:error, _reason} -> {:error, :type_mismatch}
    end
  end

  defp validate_iso_date(_value), do: {:error, :type_mismatch}

  defp validate_iso_datetime(%DateTime{} = value), do: {:ok, value}

  defp validate_iso_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      {:error, _reason} -> {:error, :type_mismatch}
    end
  end

  defp validate_iso_datetime(_value), do: {:error, :type_mismatch}

  defp validate_uri(%URI{} = value), do: {:ok, value}

  defp validate_uri(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> {:ok, value}
      _invalid -> {:error, :type_mismatch}
    end
  end

  defp validate_uri(_value), do: {:error, :type_mismatch}
end
