defmodule SpectreKinetic.Parser.Args do
  @moduledoc false

  # Internal parser plumbing. Public callers should still go through
  # SpectreKinetic.Parser; this module only keeps WITH splitting and arg
  # tokenization from turning Parser into a long hallway with bad lighting.

  # These are the only loose "KEY value" forms we accept. Without this small
  # allow-list, normal prose starts looking like arguments. I have seen that
  # movie. It does not improve on rewatch.
  @space_assign_keys ~w(
    to from cc bcc reply_to recipient phone number
    subject body text message title
    path file source dest destination target
    url uri repo branch host port method payload amount currency
  )

  @loose_value_stopwords ~w(with via using into onto in on at by for as and or)

  @explicit_arg_pattern ~r/(^|[\s,;])(?<key>[A-Za-z0-9_]+)\s*(?:=|:)\s*(?<value>"[^"]*"|'[^']*'|\{[^}]*\}|[^\s,;]+)/u
  @whitespace_chars [?\s, ?\n, ?\r, ?\t]

  @spec split_with_section(binary()) :: {binary(), binary() | nil}
  def split_with_section(text), do: do_split_with_section(text, 0, nil)

  @spec parse(binary()) :: map()
  def parse(""), do: %{}

  def parse(text) do
    explicit_args =
      text
      |> then(&Regex.scan(@explicit_arg_pattern, &1, capture: ["key", "value"]))
      |> Enum.reduce(%{}, &put_scanned_arg/2)

    parse_loose_space_args(text, explicit_args)
  end

  # Find the first real WITH token, but ignore anything inside quotes. The LLM
  # will happily put "WITH" in a subject line and then act innocent.
  defp do_split_with_section(text, index, _quote) when index >= byte_size(text), do: {text, nil}

  defp do_split_with_section(text, index, nil) do
    text
    |> :binary.at(index)
    |> split_with_section_char(text, index)
  end

  defp do_split_with_section(text, index, quote) do
    text
    |> :binary.at(index)
    |> split_quoted_with_section_char(text, index, quote)
  end

  defp split_with_section_char(quote, text, index) when quote in [?\", ?'] do
    do_split_with_section(text, index + 1, quote)
  end

  defp split_with_section_char(_char, text, index) do
    if with_token_at?(text, index) do
      {binary_part(text, 0, index) |> String.trim(), consume_with_tail(text, index + 4)}
    else
      do_split_with_section(text, index + 1, nil)
    end
  end

  defp split_quoted_with_section_char(quote, text, index, quote) do
    do_split_with_section(text, index + 1, nil)
  end

  defp split_quoted_with_section_char(_char, text, index, quote) do
    do_split_with_section(text, index + 1, quote)
  end

  defp with_token_at?(text, index) do
    enough_bytes?(text, index, 4) and
      token_boundary_before?(text, index) and
      token_boundary_after?(text, index + 4) and
      upcase_prefix(binary_part(text, index, 4), 4) == "WITH"
  end

  defp token_boundary_before?(_text, 0), do: true
  defp token_boundary_before?(text, index), do: whitespace?(text, index - 1)

  defp token_boundary_after?(text, index) when index >= byte_size(text), do: true

  defp token_boundary_after?(text, index) do
    whitespace?(text, index) or :binary.at(text, index) == ?:
  end

  defp consume_with_tail(text, index) do
    next_index =
      text
      |> skip_spaces(index)
      |> then(&skip_colon(&1, text))
      |> then(&skip_spaces(text, &1))

    binary_part(text, next_index, byte_size(text) - next_index)
  end

  # Explicit KEY=value and KEY: value are the boring reliable path. Prefer
  # these whenever they exist; loose parsing fills only the obvious gaps.
  defp skip_colon(index, text) do
    if index < byte_size(text) and :binary.at(text, index) == ?: do
      index + 1
    else
      index
    end
  end

  defp skip_spaces(text, index) do
    if index < byte_size(text) and whitespace?(text, index) do
      skip_spaces(text, index + 1)
    else
      index
    end
  end

  defp put_scanned_arg([key, value], acc),
    do: Map.put(acc, String.upcase(key), parse_arg_value(value))

  defp parse_loose_space_args(text, explicit_args) do
    text
    |> split_arg_tokens()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(explicit_args, &put_loose_space_arg/2)
  end

  # Loose pairs are a concession to real prompts, not a license to parse every
  # two words as intent. Small allow-list, stopwords, done. The rest can go
  # dance somewhere else.
  defp put_loose_space_arg([key, value], acc) do
    upper_key = String.upcase(key)
    lower_key = String.downcase(key)
    parsed_value = parse_arg_value(value)

    if loose_space_arg?(acc, upper_key, lower_key, parsed_value) do
      Map.put(acc, upper_key, parsed_value)
    else
      acc
    end
  end

  defp loose_space_arg?(acc, upper_key, lower_key, parsed_value) do
    not Map.has_key?(acc, upper_key) and
      lower_key in @space_assign_keys and
      parsed_value != "" and
      String.downcase(parsed_value) not in @loose_value_stopwords
  end

  defp split_arg_tokens(text) do
    text
    |> String.trim()
    |> String.to_charlist()
    |> Enum.reduce({[], [], nil}, &collect_arg_token/2)
    |> finalize_arg_tokens()
  end

  # Tokenization keeps quoted values together. We only track one quote char
  # because this is AL cleanup, not a new programming language. Please no.
  defp collect_arg_token(char, {tokens, current, nil})
       when char in [?\s, ?\n, ?\r, ?\t, ?,, ?;] do
    push_arg_token(tokens, current, nil)
  end

  defp collect_arg_token(char, {tokens, current, nil}) when char in [?", ?'] do
    {tokens, [char | current], char}
  end

  defp collect_arg_token(char, {tokens, current, quote}) when char == quote do
    {tokens, [char | current], nil}
  end

  defp collect_arg_token(char, {tokens, current, quote}) do
    {tokens, [char | current], quote}
  end

  defp finalize_arg_tokens({tokens, current, _quote}) do
    tokens
    |> append_arg_token(current)
    |> Enum.reverse()
  end

  defp push_arg_token(tokens, [], _quote), do: {tokens, [], nil}

  defp push_arg_token(tokens, current, quote) do
    {append_arg_token(tokens, current), [], quote}
  end

  defp append_arg_token(tokens, current) do
    case current |> Enum.reverse() |> List.to_string() |> String.trim() do
      "" -> tokens
      token -> [token | tokens]
    end
  end

  defp parse_arg_value(<<"\"", rest::binary>>), do: unquote_arg(rest, ?")
  defp parse_arg_value(<<"'", rest::binary>>), do: unquote_arg(rest, ?')
  defp parse_arg_value(value), do: value |> String.trim() |> trim_terminal_punctuation()

  defp unquote_arg(value, quote) do
    trimmed = String.trim(value)
    closing = <<quote>>

    if String.ends_with?(trimmed, closing) do
      body_size = byte_size(trimmed) - 1
      binary_part(trimmed, 0, body_size)
    else
      trimmed
    end
    |> trim_terminal_punctuation()
  end

  defp trim_terminal_punctuation(text), do: String.trim(text, " ;,.")

  defp upcase_prefix(text, size) when byte_size(text) >= size do
    text
    |> binary_part(0, size)
    |> String.upcase()
  end

  defp upcase_prefix(_text, _size), do: ""

  defp whitespace?(text, index), do: :binary.at(text, index) in @whitespace_chars
  defp enough_bytes?(text, index, size), do: byte_size(text) - index >= size
end
