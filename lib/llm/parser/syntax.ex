defmodule SpectreKinetic.Parser.Syntax do
  @moduledoc false

  @quote_prefix_chars [?\s, ?\n, ?\r, ?\t, ?=, ?:, ?,, ?;, ?(, ?[, ?{]

  @type validation_error ::
          :unterminated_al_quote
          | :unterminated_al_brace
          | :unexpected_al_brace

  @doc false
  @spec validate(binary()) :: :ok | {:error, validation_error()}
  def validate(text) when is_binary(text) do
    validate_chars(text, nil, false, nil, 0)
  end

  @doc false
  @spec outside_at?(binary(), non_neg_integer()) :: boolean()
  def outside_at?(text, index)
      when is_binary(text) and is_integer(index) and index >= 0 and index <= byte_size(text) do
    scan_to(text, 0, index, nil, false, nil)
  end

  @doc false
  @spec find_unquoted_token(binary(), binary(), non_neg_integer()) ::
          {non_neg_integer(), pos_integer()} | :nomatch
  def find_unquoted_token(text, token, minimum_index \\ 0)
      when is_binary(text) and is_binary(token) and byte_size(token) > 0 do
    text
    |> :binary.matches(token)
    |> Enum.find(:nomatch, fn {index, _size} ->
      index >= minimum_index and outside_at?(text, index)
    end)
  end

  @doc false
  @spec find_unquoted_regex(binary(), Regex.t(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | :nomatch
  def find_unquoted_regex(text, regex, minimum_index \\ 0)
      when is_binary(text) and is_integer(minimum_index) and minimum_index >= 0 do
    regex
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(:nomatch, fn
      [{index, size} | _captures] ->
        if index >= minimum_index and outside_at?(text, index), do: {index, size}

      _invalid_match ->
        nil
    end)
  end

  defp scan_to(_rest, position, target, quote, _escaped?, _previous)
       when position >= target,
    do: is_nil(quote)

  defp scan_to(<<char, rest::binary>>, position, target, nil, _escaped?, previous)
       when char in [?", ?'] do
    if quote_opener?(previous) do
      scan_to(rest, position + 1, target, char, false, char)
    else
      scan_to(rest, position + 1, target, nil, false, char)
    end
  end

  defp scan_to(<<char, rest::binary>>, position, target, nil, _escaped?, _previous),
    do: scan_to(rest, position + 1, target, nil, false, char)

  defp scan_to(<<char, rest::binary>>, position, target, quote, true, _previous),
    do: scan_to(rest, position + 1, target, quote, false, char)

  defp scan_to(<<?\\, rest::binary>>, position, target, quote, false, _previous),
    do: scan_to(rest, position + 1, target, quote, true, ?\\)

  defp scan_to(<<char, rest::binary>>, position, target, quote, false, _previous)
       when char == quote,
       do: scan_to(rest, position + 1, target, nil, false, char)

  defp scan_to(<<char, rest::binary>>, position, target, quote, false, _previous),
    do: scan_to(rest, position + 1, target, quote, false, char)

  defp scan_to(<<>>, _position, _target, quote, _escaped?, _previous), do: is_nil(quote)

  defp validate_chars(<<>>, quote, _escaped?, _previous, _brace_depth)
       when quote in [?", ?'],
       do: {:error, :unterminated_al_quote}

  defp validate_chars(<<>>, nil, _escaped?, _previous, brace_depth) when brace_depth > 0,
    do: {:error, :unterminated_al_brace}

  defp validate_chars(<<>>, nil, _escaped?, _previous, 0), do: :ok

  defp validate_chars(<<char, rest::binary>>, nil, _escaped?, previous, brace_depth)
       when char in [?", ?'] do
    if quote_opener?(previous) do
      validate_chars(rest, char, false, char, brace_depth)
    else
      validate_chars(rest, nil, false, char, brace_depth)
    end
  end

  defp validate_chars(<<?{, rest::binary>>, nil, _escaped?, _previous, brace_depth),
    do: validate_chars(rest, nil, false, ?{, brace_depth + 1)

  defp validate_chars(<<?}, _rest::binary>>, nil, _escaped?, _previous, 0),
    do: {:error, :unexpected_al_brace}

  defp validate_chars(<<?}, rest::binary>>, nil, _escaped?, _previous, brace_depth),
    do: validate_chars(rest, nil, false, ?}, brace_depth - 1)

  defp validate_chars(<<char, rest::binary>>, nil, _escaped?, _previous, brace_depth),
    do: validate_chars(rest, nil, false, char, brace_depth)

  defp validate_chars(<<char, rest::binary>>, quote, true, _previous, brace_depth),
    do: validate_chars(rest, quote, false, char, brace_depth)

  defp validate_chars(<<?\\, rest::binary>>, quote, false, _previous, brace_depth),
    do: validate_chars(rest, quote, true, ?\\, brace_depth)

  defp validate_chars(<<char, rest::binary>>, quote, false, _previous, brace_depth)
       when char == quote,
       do: validate_chars(rest, nil, false, char, brace_depth)

  defp validate_chars(<<char, rest::binary>>, quote, false, _previous, brace_depth),
    do: validate_chars(rest, quote, false, char, brace_depth)

  defp quote_opener?(nil), do: true
  defp quote_opener?(previous), do: previous in @quote_prefix_chars
end
