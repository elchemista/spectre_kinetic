defmodule SpectreKinetic.Parser.Syntax do
  @moduledoc false

  @quote_prefix_chars [?\s, ?\n, ?\r, ?\t, ?=, ?:, ?,, ?;, ?(, ?[, ?{]

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

  defp quote_opener?(nil), do: true
  defp quote_opener?(previous), do: previous in @quote_prefix_chars
end
