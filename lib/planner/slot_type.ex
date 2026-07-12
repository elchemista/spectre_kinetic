defmodule SpectreKinetic.Planner.SlotType do
  @moduledoc false

  @true_values ~w(true yes on 1)
  @false_values ~w(false no off 0)

  @spec coerce(term(), term()) :: {:ok, term()} | {:error, :type_mismatch}
  def coerce(value, type) when is_binary(type) do
    type
    |> String.split(~r/\s*\|\s*/, trim: true)
    |> coerce_union(value)
  end

  def coerce(value, _type), do: {:ok, value}

  defp coerce_union([], _value), do: {:error, :type_mismatch}

  defp coerce_union([type | rest], value) do
    case coerce_one(value, normalize_type(type)) do
      {:ok, _coerced} = ok -> ok
      {:error, :type_mismatch} -> coerce_union(rest, value)
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

  defp coerce_one(value, <<"[", _rest::binary>>) do
    if is_list(value), do: {:ok, value}, else: {:error, :type_mismatch}
  end

  defp coerce_one(value, <<"list(", _rest::binary>>) do
    if is_list(value), do: {:ok, value}, else: {:error, :type_mismatch}
  end

  defp coerce_one(value, type) when type in ["atom()", "atom"] do
    if is_atom(value), do: {:ok, value}, else: {:error, :type_mismatch}
  end

  defp coerce_one(value, type) when type in ["term()", "any()", "any"], do: {:ok, value}

  # Custom and opaque types cannot be proven here. Keep them extensible rather
  # than rejecting valid domain values the planner cannot introspect.
  defp coerce_one(value, _unknown_type), do: {:ok, value}

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
