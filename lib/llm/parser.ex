defmodule SpectreKinetic.Parser do
  @moduledoc """
  Lightweight AL normalization and validation.

  This module focuses only on AL cleanup and lightweight extraction. It:

  - unwraps common LLM wrappers like `AL:`, `<al>...</al>`, and fenced `al` blocks
  - normalizes whitespace
  - validates that a candidate looks like usable AL
  - extracts loose metadata and literal `KEY=value` args for Elixir-side helpers

  It does not perform retrieval or final slot-to-param planning.
  """

  @type parsed :: %{
          al: binary(),
          verb: binary(),
          object: binary() | nil,
          args: map()
        }

  @type validation_error ::
          :invalid_al
          | :empty_al
          | :unterminated_al_tag
          | :unterminated_al_fence
          | :invalid_al_verb

  @space_assign_keys ~w(
    to from cc bcc reply_to recipient phone number
    subject body text message title
    path file source dest destination target
    url uri repo branch host port method payload amount currency
  )

  @loose_value_stopwords ~w(with via using into onto in on at by for as and or)

  @explicit_arg_pattern ~r/(^|[\s,;])(?<key>[A-Za-z0-9_]+)\s*(?:=|:)\s*(?<value>"[^"]*"|'[^']*'|\{[^}]*\}|[^\s,;]+)/u
  @whitespace_chars [?\s, ?\n, ?\r, ?\t]
  @fence_delimiters ["```", "~~~"]
  @al_fence_languages ["al", "action", "action-language"]

  @doc """
  Normalizes AL text by unwrapping common LLM wrappers and collapsing whitespace.
  """
  @spec normalize(binary()) :: {:ok, binary()} | {:error, validation_error()}
  def normalize(al_text) when is_binary(al_text) do
    al_text
    |> String.trim()
    |> unwrap_all()
    |> case do
      {:ok, text} -> {:ok, collapse_whitespace(text)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize(_), do: {:error, :invalid_al}

  @doc """
  Validates one AL candidate after normalization.
  """
  @spec validate(binary()) :: {:ok, binary()} | {:error, validation_error()}
  def validate(al_text) do
    with {:ok, normalized} <- normalize(al_text),
         :ok <- validate_normalized(normalized) do
      {:ok, normalized}
    end
  end

  @doc """
  Parses one AL candidate into lightweight Elixir-side metadata.
  """
  @spec parse(binary()) :: parsed() | {:error, validation_error()}
  def parse(al_text) do
    with {:ok, normalized} <- validate(al_text) do
      {head, with_part} = split_with_section(normalized)
      {verb, object} = parse_verb_object(head)
      args_source = with_part || normalized

      %{
        al: normalized,
        verb: verb,
        object: object,
        args: parse_args(args_source)
      }
    end
  end

  @doc """
  Extracts literal `KEY=value` arguments from one AL instruction.
  """
  @spec args(binary()) :: map()
  def args(al_text) do
    case parse(al_text) do
      %{args: args} -> args
      {:error, _} -> %{}
    end
  end

  @doc """
  Returns the parsed argument map with lowercase keys for planner slot input.
  """
  @spec slot_map(binary()) :: map()
  def slot_map(al_text) do
    Map.new(args(al_text), fn {key, value} -> {String.downcase(key), value} end)
  end

  defp unwrap_all(""), do: {:ok, ""}

  defp unwrap_all(text) do
    text
    |> unwrap_once()
    |> unwrap_all_result(text)
  end

  defp unwrap_all_result({:ok, text}, text), do: {:ok, text}
  defp unwrap_all_result({:ok, next}, _text), do: next |> String.trim() |> unwrap_all()
  defp unwrap_all_result({:error, reason}, _text), do: {:error, reason}

  defp unwrap_once(text) do
    text
    |> unwrap_prefixed_al(prefixed_al?(text))
    |> unwrap_wrapped_tag(wrapped_tag?(text))
    |> unwrap_wrapped_al_fence(wrapped_al_fence?(text))
  end

  defp unwrap_prefixed_al(text, true), do: {:ok, text |> strip_prefix_marker() |> String.trim()}
  defp unwrap_prefixed_al(text, false), do: {:ok, text}

  defp unwrap_wrapped_tag({:ok, text}, true), do: unwrap_tag(text)
  defp unwrap_wrapped_tag(result, _wrapped?), do: result

  defp unwrap_wrapped_al_fence({:ok, text}, true), do: unwrap_al_fence(text)
  defp unwrap_wrapped_al_fence(result, _wrapped?), do: result

  defp validate_normalized(""), do: {:error, :empty_al}

  defp validate_normalized(normalized) do
    normalized
    |> first_token()
    |> validate_first_token()
  end

  defp validate_first_token(nil), do: {:error, :empty_al}
  defp validate_first_token(<<char, _::binary>>) when char in ?A..?Z or char in ?a..?z, do: :ok
  defp validate_first_token(_token), do: {:error, :invalid_al_verb}

  defp prefixed_al?(text) do
    upcase_prefix(text, 3) == "AL:"
  end

  defp strip_prefix_marker(<<"A", "L", ":", rest::binary>>), do: rest
  defp strip_prefix_marker(<<"a", "l", ":", rest::binary>>), do: rest
  defp strip_prefix_marker(rest), do: rest

  defp wrapped_tag?(text) do
    lower = String.downcase(text)
    String.starts_with?(lower, "<al") and String.contains?(lower, "</al>")
  end

  defp unwrap_tag(text) do
    lower = String.downcase(text)
    open_end = :binary.match(lower, ">")
    close_start = :binary.match(lower, "</al>")

    unwrap_tag_result(text, open_end, close_start)
  end

  defp unwrap_tag_result(text, {open_index, 1}, {close_index, 5})
       when close_index > open_index do
    inner_start = open_index + 1
    inner_size = close_index - inner_start
    {:ok, binary_part(text, inner_start, inner_size)}
  end

  defp unwrap_tag_result(_text, {_open_index, 1}, :nomatch), do: {:error, :unterminated_al_tag}
  defp unwrap_tag_result(text, _open_end, _close_start), do: {:ok, text}

  defp wrapped_al_fence?(text) do
    text
    |> opening_fence()
    |> wrapped_al_fence_result?()
  end

  defp wrapped_al_fence_result?({delimiter, _language, _rest})
       when delimiter in @fence_delimiters,
       do: true

  defp wrapped_al_fence_result?(_result), do: false

  defp unwrap_al_fence(text) do
    text
    |> opening_fence()
    |> unwrap_al_fence_result(text)
  end

  defp unwrap_al_fence_result({delimiter, language, rest}, _text)
       when language in @al_fence_languages do
    unwrap_known_al_fence(rest, delimiter)
  end

  defp unwrap_al_fence_result(_result, text), do: {:ok, text}

  defp unwrap_known_al_fence(rest, delimiter) do
    close_token = "\n" <> delimiter

    case :binary.match(rest, close_token) do
      {close_index, _size} ->
        {:ok, binary_part(rest, 0, close_index)}

      :nomatch ->
        unwrap_trailing_fence(rest, delimiter)
    end
  end

  defp unwrap_trailing_fence(rest, delimiter) do
    trailing = String.trim_trailing(rest)

    if String.ends_with?(trailing, delimiter) do
      body_size = byte_size(trailing) - byte_size(delimiter)
      {:ok, binary_part(trailing, 0, body_size)}
    else
      {:error, :unterminated_al_fence}
    end
  end

  defp opening_fence(<<delimiter::binary-size(3), rest::binary>>)
       when delimiter in ["```", "~~~"] do
    {info_line, remaining} = split_once(rest, "\n")
    {language, body_prefix} = parse_fence_info(info_line)
    {delimiter, language, body_prefix <> remaining}
  end

  defp opening_fence(_text), do: :error

  defp parse_fence_info(info_line) do
    trimmed = String.trim_leading(info_line)

    trimmed
    |> split_first_word()
    |> parse_fence_info_result()
  end

  defp parse_fence_info_result({language, rest}),
    do: {String.downcase(language), String.trim_leading(rest)}

  defp parse_fence_info_result(nil), do: {"", ""}

  defp split_with_section(text), do: do_split_with_section(text, 0, nil)

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

  defp parse_verb_object(head) do
    head
    |> String.trim()
    |> String.split(" ", parts: 2)
    |> parse_verb_object_parts()
  end

  defp parse_verb_object_parts([verb]), do: {String.upcase(verb), nil}

  defp parse_verb_object_parts([verb, rest]) do
    {String.upcase(verb), normalize_object(rest)}
  end

  defp normalize_object(rest) do
    rest
    |> String.trim()
    |> trim_terminal_punctuation()
    |> normalize_object_result()
  end

  defp normalize_object_result(""), do: nil
  defp normalize_object_result(object), do: object

  defp parse_args(""), do: %{}

  defp parse_args(text) do
    explicit_args =
      text
      |> then(&Regex.scan(@explicit_arg_pattern, &1, capture: ["key", "value"]))
      |> Enum.reduce(%{}, &put_scanned_arg/2)

    parse_loose_space_args(text, explicit_args)
  end

  defp put_scanned_arg([key, value], acc),
    do: Map.put(acc, String.upcase(key), parse_arg_value(value))

  defp parse_loose_space_args(text, explicit_args) do
    text
    |> split_arg_tokens()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(explicit_args, &put_loose_space_arg/2)
  end

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

  defp first_token(text) do
    text
    |> String.split(" ", parts: 2, trim: true)
    |> List.first()
  end

  defp collapse_whitespace(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce({[], nil, false}, &collapse_char/2)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
    |> String.trim()
  end

  defp collapse_char(char, {acc, quote, _spaced?}) when quote in [?", ?'] and char == quote,
    do: {[char | acc], nil, false}

  defp collapse_char(char, {acc, quote, _spaced?}) when quote in [?", ?'],
    do: {[char | acc], quote, false}

  defp collapse_char(char, {acc, nil, _spaced?}) when char in [?", ?'],
    do: {[char | acc], char, false}

  defp collapse_char(char, {acc, nil, true}) when char in @whitespace_chars,
    do: {acc, nil, true}

  defp collapse_char(char, {acc, nil, false}) when char in @whitespace_chars,
    do: {[?\s | acc], nil, true}

  defp collapse_char(char, {acc, nil, _spaced?}), do: {[char | acc], nil, false}

  defp trim_terminal_punctuation(text), do: String.trim(text, " ;,.")

  defp split_once(text, separator) do
    text
    |> :binary.match(separator)
    |> split_once_result(text)
  end

  defp split_once_result({index, size}, text) do
    {
      binary_part(text, 0, index),
      binary_part(text, index + size, byte_size(text) - index - size)
    }
  end

  defp split_once_result(:nomatch, text), do: {text, ""}

  defp split_first_word(""), do: nil

  defp split_first_word(text) do
    text
    |> String.split(" ", parts: 2, trim: true)
    |> split_first_word_result()
  end

  defp split_first_word_result([word, rest]), do: {word, rest}
  defp split_first_word_result([word]), do: {word, ""}
  defp split_first_word_result(_parts), do: nil

  defp upcase_prefix(text, size) when byte_size(text) >= size do
    text
    |> binary_part(0, size)
    |> String.upcase()
  end

  defp upcase_prefix(_text, _size), do: ""

  defp whitespace?(text, index), do: :binary.at(text, index) in @whitespace_chars
  defp enough_bytes?(text, index, size), do: byte_size(text) - index >= size
end
