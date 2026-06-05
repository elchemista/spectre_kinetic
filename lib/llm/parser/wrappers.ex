defmodule SpectreKinetic.Parser.Wrappers do
  @moduledoc false

  # Internal wrapper cleanup for one AL candidate. The extractor deals with
  # noisy full responses; this module deals with a single candidate wearing
  # Markdown, XML-ish tags, or the classic "AL:" hat.

  @type validation_error ::
          :unterminated_al_tag
          | :unterminated_al_fence

  @whitespace_chars [?\s, ?\n, ?\r, ?\t]
  @fence_delimiters ["```", "~~~"]
  @al_fence_languages ["al", "action", "action-language"]

  @spec normalize(binary()) :: {:ok, binary()} | {:error, validation_error()}
  def normalize(text) do
    case unwrap_all(String.trim(text)) do
      {:ok, unwrapped} -> {:ok, collapse_whitespace(unwrapped)}
      {:error, reason} -> {:error, reason}
    end
  end

  # LLM wrappers arrive like little gift boxes full of chores. Peel one layer,
  # then check again because models do enjoy nesting the ceremony.
  defp unwrap_all(""), do: {:ok, ""}

  defp unwrap_all(text) do
    case unwrap_once(text) do
      {:ok, ^text} -> {:ok, text}
      {:ok, next} -> next |> String.trim() |> unwrap_all()
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap_once(text) do
    with {:ok, text} <- unwrap_prefixed_al(text),
         {:ok, text} <- unwrap_wrapped_tag(text) do
      unwrap_wrapped_al_fence(text)
    end
  end

  # AL: <al>```al SEND EMAIL```</al> is ugly, but it happens. Each wrapper type
  # gets one small function so the unwrap order stays boring and visible.
  defp unwrap_prefixed_al(text) do
    if prefixed_al?(text) do
      {:ok, text |> strip_prefix_marker() |> String.trim()}
    else
      {:ok, text}
    end
  end

  defp unwrap_wrapped_tag(text) do
    if wrapped_tag?(text), do: unwrap_tag(text), else: {:ok, text}
  end

  defp unwrap_wrapped_al_fence(text) do
    if wrapped_al_fence?(text), do: unwrap_al_fence(text), else: {:ok, text}
  end

  defp prefixed_al?(text), do: upcase_prefix(text, 3) == "AL:"

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

  # Tags are only valid wrappers when we can see both ends. A missing close tag
  # is a diagnostic, not something we silently swallow and regret later.
  defp unwrap_tag_result(text, {open_index, 1}, {close_index, 5})
       when close_index > open_index do
    inner_start = open_index + 1
    inner_size = close_index - inner_start
    {:ok, binary_part(text, inner_start, inner_size)}
  end

  defp unwrap_tag_result(_text, {_open_index, 1}, :nomatch), do: {:error, :unterminated_al_tag}
  defp unwrap_tag_result(text, _open_end, _close_start), do: {:ok, text}

  defp wrapped_al_fence?(text), do: opening_fence?(opening_fence(text))

  defp opening_fence?({delimiter, _language, _rest})
       when delimiter in @fence_delimiters,
       do: true

  defp opening_fence?(_result), do: false

  defp unwrap_al_fence(text) do
    text
    |> opening_fence()
    |> unwrap_al_fence_result(text)
  end

  # Only AL-ish fences are unwrapped here. Other fenced text belongs to the
  # caller's clean text, not to the planner. JSON pretending to be AL can stay
  # outside and think about what it did.
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

  # Whitespace is normalized after wrapper removal, but quoted values keep their
  # inner spaces. This keeps BODY="hello there" from becoming a small tragedy.
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
end
