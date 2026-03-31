defmodule SpectreKinetic.Parser do
  @moduledoc """
  Lightweight AL normalization and validation.

  The Rust engine remains the source of truth for planning. This module only:

  - unwraps common LLM wrappers like `AL:`, `<al>...</al>`, and fenced `al` blocks
  - normalizes whitespace
  - validates that a candidate looks like usable AL
  - extracts loose metadata and literal `KEY=value` args for Elixir-side helpers

  It does not replace the Rust AL parser. In particular, the engine's action-text
  retrieval, placeholder handling, and slot-to-param matching still live in
  `spectre-core`.
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

  @spec validate(binary()) :: {:ok, binary()} | {:error, validation_error()}
  def validate(al_text) do
    with {:ok, normalized} <- normalize(al_text),
         :ok <- validate_normalized(normalized) do
      {:ok, normalized}
    end
  end

  @spec parse(binary()) :: parsed() | {:error, validation_error()}
  def parse(al_text) do
    with {:ok, normalized} <- validate(al_text) do
      {head, with_part} = split_with_section(normalized)
      {verb, object} = parse_verb_object(head)

      %{
        al: normalized,
        verb: verb,
        object: object,
        args: parse_args(with_part || "")
      }
    end
  end

  @spec args(binary()) :: map()
  def args(al_text) do
    case parse(al_text) do
      %{args: args} -> args
      {:error, _} -> %{}
    end
  end

  @spec slot_map(binary()) :: map()
  def slot_map(al_text) do
    Map.new(args(al_text), fn {key, value} -> {String.downcase(key), value} end)
  end

  defp unwrap_all(""), do: {:ok, ""}

  defp unwrap_all(text) do
    case unwrap_once(text) do
      {:ok, ^text} -> {:ok, text}
      {:ok, next} -> next |> String.trim() |> unwrap_all()
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap_once(text) do
    cond do
      prefixed_al?(text) -> {:ok, text |> strip_prefix_marker() |> String.trim()}
      wrapped_tag?(text) -> unwrap_tag(text)
      wrapped_al_fence?(text) -> unwrap_al_fence(text)
      true -> {:ok, text}
    end
  end

  defp validate_normalized(""), do: {:error, :empty_al}

  defp validate_normalized(normalized) do
    case first_token(normalized) do
      nil -> {:error, :empty_al}
      <<char, _::binary>> = _token when char in ?A..?Z or char in ?a..?z -> :ok
      _ -> {:error, :invalid_al_verb}
    end
  end

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

    case {open_end, close_start} do
      {{open_index, 1}, {close_index, 5}} when close_index > open_index ->
        inner_start = open_index + 1
        inner_size = close_index - inner_start
        {:ok, binary_part(text, inner_start, inner_size)}

      {{_open_index, 1}, :nomatch} ->
        {:error, :unterminated_al_tag}

      _ ->
        {:ok, text}
    end
  end

  defp wrapped_al_fence?(text) do
    case opening_fence(text) do
      {delimiter, _language, _rest} when delimiter in ["```", "~~~"] -> true
      _ -> false
    end
  end

  defp unwrap_al_fence(text) do
    case opening_fence(text) do
      {delimiter, language, rest} when language in ["al", "action", "action-language"] ->
        close_token = "\n" <> delimiter

        case :binary.match(rest, close_token) do
          {close_index, _size} ->
            {:ok, binary_part(rest, 0, close_index)}

          :nomatch ->
            if String.ends_with?(String.trim_trailing(rest), delimiter) do
              trailing = String.trim_trailing(rest)
              body_size = byte_size(trailing) - byte_size(delimiter)
              {:ok, binary_part(trailing, 0, body_size)}
            else
              {:error, :unterminated_al_fence}
            end
        end

      {_delimiter, _language, _rest} ->
        {:ok, text}

      :error ->
        {:ok, text}
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

    case split_first_word(trimmed) do
      {language, rest} -> {String.downcase(language), String.trim_leading(rest)}
      nil -> {"", ""}
    end
  end

  defp split_with_section(text), do: do_split_with_section(text, 0, nil)

  defp do_split_with_section(text, index, _quote) when index >= byte_size(text), do: {text, nil}

  defp do_split_with_section(text, index, nil) do
    case :binary.at(text, index) do
      quote when quote in [?\", ?'] ->
        do_split_with_section(text, index + 1, quote)

      _char ->
        if with_token_at?(text, index) do
          {binary_part(text, 0, index) |> String.trim(), consume_with_tail(text, index + 4)}
        else
          do_split_with_section(text, index + 1, nil)
        end
    end
  end

  defp do_split_with_section(text, index, quote) do
    case :binary.at(text, index) do
      ^quote -> do_split_with_section(text, index + 1, nil)
      _ -> do_split_with_section(text, index + 1, quote)
    end
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
    case String.split(String.trim(head), " ", parts: 2) do
      [verb] -> {String.upcase(verb), nil}
      [verb, rest] -> {String.upcase(verb), normalize_object(rest)}
    end
  end

  defp normalize_object(rest) do
    rest
    |> String.trim()
    |> trim_terminal_punctuation()
    |> case do
      "" -> nil
      object -> object
    end
  end

  defp parse_args(""), do: %{}

  defp parse_args(text) do
    text
    |> split_arg_tokens()
    |> Enum.reduce(%{}, &put_arg_token/2)
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

  defp put_arg_token(token, acc) do
    case split_arg_assignment(token) do
      {key, value} -> Map.put(acc, String.upcase(key), value)
      :error -> acc
    end
  end

  defp split_arg_assignment(token) do
    case :binary.match(token, "=") do
      {index, 1} ->
        key = binary_part(token, 0, index) |> String.trim()
        value = binary_part(token, index + 1, byte_size(token) - index - 1) |> parse_arg_value()

        if valid_arg_key?(key) and value != "" do
          {key, value}
        else
          :error
        end

      :nomatch ->
        :error
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

  defp valid_arg_key?(key) do
    key != "" and
      String.to_charlist(key)
      |> Enum.all?(fn char ->
        char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_
      end)
  end

  defp first_token(text) do
    text
    |> String.split(" ", parts: 2, trim: true)
    |> List.first()
  end

  defp collapse_whitespace(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce({[], nil, false}, fn char, {acc, quote, spaced?} ->
      cond do
        quote && char == quote ->
          {[char | acc], nil, false}

        quote ->
          {[char | acc], quote, false}

        char in [?", ?'] ->
          {[char | acc], char, false}

        char in [?\s, ?\n, ?\r, ?\t] and spaced? ->
          {acc, nil, true}

        char in [?\s, ?\n, ?\r, ?\t] ->
          {[?\s | acc], nil, true}

        true ->
          {[char | acc], nil, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
    |> String.trim()
  end

  defp trim_terminal_punctuation(text), do: String.trim(text, " ;,.")

  defp split_once(text, separator) do
    case :binary.match(text, separator) do
      {index, size} ->
        {
          binary_part(text, 0, index),
          binary_part(text, index + size, byte_size(text) - index - size)
        }

      :nomatch ->
        {text, ""}
    end
  end

  defp split_first_word(""), do: nil

  defp split_first_word(text) do
    case String.split(text, " ", parts: 2, trim: true) do
      [word, rest] -> {word, rest}
      [word] -> {word, ""}
      _ -> nil
    end
  end

  defp upcase_prefix(text, size) when byte_size(text) >= size do
    text
    |> binary_part(0, size)
    |> String.upcase()
  end

  defp upcase_prefix(_text, _size), do: ""

  defp whitespace?(text, index), do: :binary.at(text, index) in [?\s, ?\n, ?\r, ?\t]
  defp enough_bytes?(text, index, size), do: byte_size(text) - index >= size
end
