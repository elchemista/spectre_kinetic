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

  @space_assign_keys ~w(
    to from cc bcc reply_to recipient phone number
    subject body text message title
    path file source dest destination target
    url uri repo branch host port method payload amount currency
  )

  @loose_value_stopwords ~w(with via using into onto in on at by for as and or)

  @explicit_arg_pattern ~r/(^|[\s,;])(?<key>[A-Za-z0-9_]+)\s*(?:=|:)\s*(?<value>"[^"]*"|'[^']*'|\{[^}]*\}|[^\s,;]+)/u

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
        unwrap_known_al_fence(rest, delimiter)

      {_delimiter, _language, _rest} ->
        {:ok, text}

      :error ->
        {:ok, text}
    end
  end

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
    |> Enum.reduce(explicit_args, fn [key, value], acc ->
      upper_key = String.upcase(key)
      lower_key = String.downcase(key)
      parsed_value = parse_arg_value(value)

      cond do
        Map.has_key?(acc, upper_key) -> acc
        lower_key not in @space_assign_keys -> acc
        parsed_value == "" -> acc
        String.downcase(parsed_value) in @loose_value_stopwords -> acc
        true -> Map.put(acc, upper_key, parsed_value)
      end
    end)
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
