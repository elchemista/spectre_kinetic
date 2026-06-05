defmodule SpectreKinetic.Extractor.Fences do
  @moduledoc false

  # Markdown fence grammar for the response scanner. This module returns raw AL
  # chunks and clean text pieces; validation stays in Extractor so diagnostics
  # all pass through one door.

  @al_fence_languages ["al", "action", "action-language"]

  @spec parse_open(binary()) ::
          {:al_inline, binary()}
          | {:al_open, binary(), binary()}
          | {:plain_open, binary()}
          | :not_a_fence
  def parse_open(trimmed_line) do
    case fence_delimiter(trimmed_line) do
      {delimiter, rest} ->
        parse_open_with_delimiter(delimiter, rest)

      :error ->
        :not_a_fence
    end
  end

  @spec parse_close(binary(), binary()) :: {:close, binary(), binary()} | :continue
  def parse_close(line, delimiter) do
    line
    |> String.trim_leading()
    |> fence_close(delimiter)
  end

  @spec plain_close?(binary(), binary()) :: boolean()
  def plain_close?(line, delimiter) do
    String.starts_with?(String.trim_leading(line), delimiter)
  end

  @spec extract_inline_segments(binary()) :: {:ok, binary(), [binary()]}
  def extract_inline_segments(line) do
    case extract_inline(line, [], []) do
      {:ok, clean_parts, raws} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(clean_parts)), Enum.reverse(raws)}
    end
  end

  # Opening fences can be one-line AL, multi-line AL, or plain Markdown. The
  # plain case matters because clean text should keep normal code blocks.
  defp parse_open_with_delimiter(delimiter, rest) do
    case split_first_token(String.trim_leading(rest)) do
      {language, content} -> parse_fence_language(delimiter, language, content)
      :error -> {:plain_open, delimiter}
    end
  end

  defp parse_fence_language(delimiter, language, content) do
    if al_fence_language?(language),
      do: parse_fence_body(delimiter, content),
      else: {:plain_open, delimiter}
  end

  defp parse_fence_body(delimiter, content) do
    case split_inline_fence_close(content, delimiter) do
      {:ok, body, _rest} -> {:al_inline, body}
      :not_found -> {:al_open, delimiter, String.trim_leading(content)}
    end
  end

  defp extract_inline("", clean_parts, raws), do: {:ok, clean_parts, raws}

  # Inline fences are scanned left-to-right and removed from clean text only
  # when the language is AL-ish. Other backticks stay where the human put them.
  defp extract_inline(line, clean_parts, raws) do
    case next_inline_fence(line) do
      :not_found ->
        {:ok, [line | clean_parts], raws}

      {index, delimiter} ->
        before = binary_part(line, 0, index)
        rest = binary_part(line, index, byte_size(line) - index)

        case parse_inline_al_fence(rest, delimiter) do
          {:ok, raw, after_close} ->
            extract_inline(after_close, [before | clean_parts], [raw | raws])

          _not_al_or_inline ->
            {:ok, [line | clean_parts], raws}
        end
    end
  end

  defp parse_inline_al_fence(rest, delimiter) do
    case fence_delimiter(rest) do
      {^delimiter, after_delimiter} ->
        parse_inline_al_body(after_delimiter, delimiter)

      :error ->
        :not_al
    end
  end

  defp parse_inline_al_body(after_delimiter, delimiter) do
    case split_first_token(String.trim_leading(after_delimiter)) do
      {language, content} -> parse_inline_al_language(language, content, delimiter)
      :error -> :not_al
    end
  end

  defp parse_inline_al_language(language, content, delimiter) do
    if al_fence_language?(language),
      do: parse_inline_al_content(content, delimiter),
      else: :not_al
  end

  defp parse_inline_al_content(content, delimiter) do
    case split_inline_fence_close(content, delimiter) do
      {:ok, body, after_close} -> {:ok, body, after_close}
      :not_found -> :not_inline
    end
  end

  defp fence_close(delimiter, delimiter), do: {:close, "", ""}

  # A closing fence may have text after it. Feed that text back to Extractor;
  # models love trailing commentary, because apparently one output was too easy.
  defp fence_close(trimmed, delimiter) do
    if String.starts_with?(trimmed, delimiter),
      do: {:close, "", trimmed |> delimiter_tail(delimiter) |> String.trim_leading()},
      else: :continue
  end

  defp al_fence_language?(language), do: String.downcase(language) in @al_fence_languages

  defp split_inline_fence_close(content, delimiter) do
    case :binary.match(content, delimiter) do
      {index, size} ->
        {:ok, binary_part(content, 0, index),
         binary_part(content, index + size, byte_size(content) - index - size)}

      :nomatch ->
        :not_found
    end
  end

  defp split_first_token(""), do: :error

  defp split_first_token(text) do
    case String.split(text, " ", parts: 2, trim: true) do
      [token, rest] -> {String.trim(token), String.trim_leading(rest)}
      [token] -> {String.trim(token), ""}
      _ -> :error
    end
  end

  defp fence_delimiter(<<delimiter::binary-size(3), rest::binary>>)
       when delimiter in ["```", "~~~"],
       do: {delimiter, rest}

  defp fence_delimiter(_line), do: :error

  defp delimiter_tail(text, delimiter) do
    offset = byte_size(delimiter)
    binary_part(text, offset, byte_size(text) - offset)
  end

  # Pick whichever fence delimiter appears first. Simple, explicit, less clever
  # than a regex pretending to be a parser.
  defp next_inline_fence(line) do
    [find_delimiter(line, "```"), find_delimiter(line, "~~~")]
    |> Enum.reject(&(&1 == :not_found))
    |> Enum.min_by(fn {index, _delimiter} -> index end, fn -> :not_found end)
  end

  defp find_delimiter(line, delimiter) do
    case :binary.match(line, delimiter) do
      {index, _size} -> {index, delimiter}
      :nomatch -> :not_found
    end
  end
end
