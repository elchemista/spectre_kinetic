defmodule SpectreKinetic.Extractor do
  @moduledoc """
  Extracts AL candidates from LLM responses.

  Supported forms:

  - `AL: SEND EMAIL`
  - `<al>SEND EMAIL</al>`
  - multi-line `<al> ... </al>`
  - ```` ```al ... ``` ````
  - one-line ```` ```al SEND EMAIL``` ````

  Use `scan/1` when you need validation diagnostics. `extract/1` keeps the old
  compact `{clean_text, actions}` API and returns only validated AL strings.

  The extractor is a primary adapter for noisy LLM text. It accepts foreign
  presentation details such as Markdown fences, XML-ish tags, bullet prefixes,
  and inline `AL:` markers, then hands the rest of the system normalized AL.
  That keeps planner modules from knowing about prompt formatting quirks.

  ## Examples

      iex> SpectreKinetic.Extractor.extract("Please do this:\\n```al\\nSEND EMAIL\\n```")
      {"Please do this:", ["SEND EMAIL"]}

      iex> result = SpectreKinetic.Extractor.scan("<al>SEND EMAIL</al> then explain")
      iex> Enum.map(result.entries, & &1.al)
      ["SEND EMAIL"]
  """

  @type entry :: %{
          raw: binary(),
          al: binary() | nil,
          error: term() | nil
        }

  @type scan_result :: %{
          clean_text: binary(),
          entries: [entry()]
        }

  @al_fence_languages ["al", "action", "action-language"]

  @doc """
  Extracts validated AL strings from a noisy text response.

  Returns `{clean_text, actions}` for callers that only need executable AL.
  Invalid AL candidates are omitted from `actions`; use `scan/1` when the caller
  needs to show diagnostics for those invalid candidates.
  """
  @spec extract(binary()) :: {binary(), [binary()]}
  def extract(text) when is_binary(text) do
    result = scan(text)
    {result.clean_text, Enum.flat_map(result.entries, &entry_to_actions/1)}
  end

  def extract(_), do: {"", []}

  @doc """
  Scans a text response for AL candidates and returns validation diagnostics.

  This function preserves enough information to explain parser decisions:
  `:raw` is the extracted candidate, `:al` is the normalized candidate when it
  validates, and `:error` contains the validation reason when it does not.

  ## Example

      iex> result = SpectreKinetic.Extractor.scan("AL: 123")
      iex> [%{raw: "123", al: nil, error: :invalid_al_verb}] = result.entries
      iex> result.clean_text
      ""
  """
  @spec scan(binary()) :: scan_result()
  def scan(text) when is_binary(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce(%{mode: :normal, clean_lines: [], entries: []}, &consume_line/2)
    |> finalize_scan()
  end

  def scan(_), do: %{clean_text: "", entries: []}

  # We build lists backwards because appending line-by-line is how tiny scripts
  # become tiny regrets. The public result is put back in order at the boundary.
  defp consume_line(line, %{mode: :normal} = state) do
    trimmed = String.trim_leading(line)
    fence_candidate = drop_list_prefix(trimmed)

    case parse_fence_open(fence_candidate) do
      {:al_inline, raw} ->
        state |> add_entry(raw) |> keep_clean("")

      {:al_open, delimiter, initial} ->
        %{state | mode: {:al_fence, delimiter, [initial]}}

      {:plain_open, delimiter} ->
        state
        |> keep_clean(line)
        |> Map.put(:mode, {:plain_fence, delimiter})

      :not_a_fence ->
        handle_normal_line(line, state)
    end
  end

  defp consume_line(line, %{mode: {:al_fence, delimiter, parts}} = state) do
    case parse_fence_close(line, delimiter) do
      {:close, before_close, after_close} ->
        %{state | mode: :normal}
        |> add_entry(multiline_raw(parts, before_close))
        |> continue_after_close(after_close)

      :continue ->
        %{state | mode: {:al_fence, delimiter, [line | parts]}}
    end
  end

  defp consume_line(line, %{mode: {:al_tag, parts}} = state) do
    case split_al_close(line) do
      {:ok, before_close, after_close} ->
        %{state | mode: :normal}
        |> add_entry(multiline_raw(parts, before_close))
        |> continue_after_tag_close(after_close)

      :not_found ->
        %{state | mode: {:al_tag, [line | parts]}}
    end
  end

  defp consume_line(line, %{mode: {:plain_fence, delimiter}} = state) do
    next_state =
      if plain_fence_close?(line, delimiter) do
        %{state | mode: :normal}
      else
        state
      end

    keep_clean(next_state, line)
  end

  defp finalize_scan(%{
         mode: {:al_fence, _delimiter, parts},
         clean_lines: clean_lines,
         entries: entries
       }) do
    entry = invalid_entry(parts |> Enum.reverse() |> Enum.join("\n"), :unterminated_al_fence)
    build_result(clean_lines, [entry | entries])
  end

  defp finalize_scan(%{mode: {:al_tag, parts}, clean_lines: clean_lines, entries: entries}) do
    entry = invalid_entry(parts |> Enum.reverse() |> Enum.join("\n"), :unterminated_al_tag)
    build_result(clean_lines, [entry | entries])
  end

  defp finalize_scan(%{clean_lines: clean_lines, entries: entries}) do
    build_result(clean_lines, entries)
  end

  defp build_result(clean_lines, entries) do
    %{
      clean_text:
        clean_lines
        |> Enum.reverse()
        |> Enum.join("\n")
        |> collapse_blank_lines()
        |> String.trim(),
      entries: Enum.reverse(entries)
    }
  end

  defp handle_normal_line(line, state) do
    line
    |> extract_tagged_segments([], [])
    |> handle_tagged_segments_result(state)
  end

  defp handle_tagged_segments_result({:tag_open, clean_parts, parts}, state) do
    state
    |> keep_clean(IO.iodata_to_binary(Enum.reverse(clean_parts)))
    |> Map.put(:mode, {:al_tag, [IO.iodata_to_binary(Enum.reverse(parts))]})
  end

  defp handle_tagged_segments_result({:ok, clean_parts, entries}, state) do
    clean_line = IO.iodata_to_binary(Enum.reverse(clean_parts))
    {:ok, inline_clean_parts, inline_entries} = extract_inline_fence_segments(clean_line, [], [])
    clean_line = IO.iodata_to_binary(Enum.reverse(inline_clean_parts))

    state
    |> append_entries(entries)
    |> append_entries(inline_entries)
    |> keep_prefixed_al_or_clean(clean_line)
  end

  defp append_entries(state, entries), do: Enum.reduce(entries, state, &append_entry/2)

  defp keep_prefixed_al_or_clean(state, clean_line) do
    clean_line
    |> al_prefixed_candidate()
    |> keep_prefixed_al_or_clean_result(state, clean_line)
  end

  defp keep_prefixed_al_or_clean_result({:ok, raw}, state, _clean_line) do
    state |> add_entry(raw) |> keep_clean("")
  end

  defp keep_prefixed_al_or_clean_result(:not_al, state, clean_line),
    do: keep_clean(state, clean_line)

  defp extract_tagged_segments("", clean_parts, entries),
    do: {:ok, clean_parts, Enum.reverse(entries)}

  defp extract_tagged_segments(line, clean_parts, entries) do
    line
    |> split_al_open()
    |> extract_tagged_segments_result(line, clean_parts, entries)
  end

  defp extract_tagged_segments_result(:not_found, line, clean_parts, entries) do
    {:ok, [line | clean_parts], Enum.reverse(entries)}
  end

  defp extract_tagged_segments_result({:ok, before, inside_open}, _line, clean_parts, entries) do
    inside_open
    |> split_al_close()
    |> extract_al_close_result(before, inside_open, clean_parts, entries)
  end

  defp extract_al_close_result(
         {:ok, raw, after_close},
         before,
         _inside_open,
         clean_parts,
         entries
       ) do
    extract_tagged_segments(after_close, [before | clean_parts], [build_entry(raw) | entries])
  end

  defp extract_al_close_result(:not_found, before, inside_open, clean_parts, _entries) do
    {:tag_open, [before | clean_parts], [inside_open]}
  end

  defp extract_inline_fence_segments("", clean_parts, entries),
    do: {:ok, clean_parts, Enum.reverse(entries)}

  defp extract_inline_fence_segments(line, clean_parts, entries) do
    line
    |> next_inline_fence()
    |> extract_inline_fence_result(line, clean_parts, entries)
  end

  defp extract_inline_fence_result(:not_found, line, clean_parts, entries) do
    {:ok, [line | clean_parts], Enum.reverse(entries)}
  end

  defp extract_inline_fence_result({index, delimiter}, line, clean_parts, entries) do
    before = binary_part(line, 0, index)
    rest = binary_part(line, index, byte_size(line) - index)

    rest
    |> parse_inline_al_fence(delimiter)
    |> extract_inline_al_result(line, before, clean_parts, entries)
  end

  defp extract_inline_al_result({:ok, raw, after_close}, _line, before, clean_parts, entries) do
    extract_inline_fence_segments(after_close, [before | clean_parts], [
      build_entry(raw) | entries
    ])
  end

  defp extract_inline_al_result(_not_al_or_inline, line, _before, clean_parts, entries) do
    {:ok, [line | clean_parts], Enum.reverse(entries)}
  end

  defp continue_after_close(state, ""), do: keep_clean(state, "")
  defp continue_after_close(state, after_close), do: handle_normal_line(after_close, state)
  defp continue_after_tag_close(state, ""), do: keep_clean(state, "")
  defp continue_after_tag_close(state, after_close), do: handle_normal_line(after_close, state)

  defp keep_clean(state, line), do: %{state | clean_lines: [line | state.clean_lines]}

  defp add_entry(state, raw), do: append_entry(build_entry(raw), state)
  defp append_entry(entry, state), do: %{state | entries: [entry | state.entries]}

  defp multiline_raw(previous_parts, final_part) do
    [final_part | previous_parts]
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp build_entry(raw) do
    case SpectreKinetic.Parser.validate(raw) do
      {:ok, al} -> %{raw: raw, al: al, error: nil}
      {:error, reason} -> invalid_entry(raw, reason)
    end
  end

  defp invalid_entry(raw, reason), do: %{raw: raw, al: nil, error: reason}
  defp entry_to_actions(%{al: nil}), do: []
  defp entry_to_actions(%{al: al}), do: [al]

  defp parse_fence_open(trimmed_line) do
    case fence_delimiter(trimmed_line) do
      {delimiter, rest} ->
        parse_fence_open_with_delimiter(delimiter, rest)

      :error ->
        :not_a_fence
    end
  end

  defp parse_fence_open_with_delimiter(delimiter, rest) do
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

  defp parse_fence_close(line, delimiter) do
    line
    |> String.trim_leading()
    |> fence_close(delimiter)
  end

  defp fence_close(delimiter, delimiter), do: {:close, "", ""}

  defp fence_close(trimmed, delimiter) do
    if String.starts_with?(trimmed, delimiter),
      do: {:close, "", trimmed |> delimiter_tail(delimiter) |> String.trim_leading()},
      else: :continue
  end

  defp al_fence_language?(language), do: String.downcase(language) in @al_fence_languages

  defp plain_fence_close?(line, delimiter) do
    String.starts_with?(String.trim_leading(line), delimiter)
  end

  defp al_prefixed_candidate(line) do
    candidate = line |> String.trim_leading() |> drop_list_prefix()

    case candidate do
      <<"A", "L", ":", rest::binary>> -> {:ok, String.trim(rest)}
      <<"a", "l", ":", rest::binary>> -> {:ok, String.trim(rest)}
      _ -> :not_al
    end
  end

  defp drop_list_prefix(<<"-", rest::binary>>), do: String.trim_leading(rest)
  defp drop_list_prefix(<<"*", rest::binary>>), do: String.trim_leading(rest)

  defp drop_list_prefix(text) do
    case read_leading_number(text) do
      {:ok, rest} -> String.trim_leading(rest)
      :error -> text
    end
  end

  defp read_leading_number(text) do
    {digits, rest} = take_digits(text, [])

    case {digits, rest} do
      {[], _} -> :error
      {_digits, <<".", tail::binary>>} -> {:ok, tail}
      {_digits, <<")", tail::binary>>} -> {:ok, tail}
      _ -> :error
    end
  end

  defp take_digits(<<char, rest::binary>>, acc) when char in ?0..?9,
    do: take_digits(rest, [char | acc])

  defp take_digits(rest, acc), do: {Enum.reverse(acc), rest}

  defp split_al_open(line) do
    lower = String.downcase(line)

    case :binary.match(lower, "<al") do
      {open_index, _size} ->
        rest = binary_part(line, open_index, byte_size(line) - open_index)
        lower_rest = binary_part(lower, open_index, byte_size(lower) - open_index)

        case :binary.match(lower_rest, ">") do
          {gt_index, 1} ->
            {
              :ok,
              binary_part(line, 0, open_index),
              binary_part(rest, gt_index + 1, byte_size(rest) - gt_index - 1)
            }

          :nomatch ->
            :not_found
        end

      :nomatch ->
        :not_found
    end
  end

  defp split_al_close(line) do
    lower = String.downcase(line)

    case :binary.match(lower, "</al>") do
      {close_index, 5} ->
        {
          :ok,
          binary_part(line, 0, close_index),
          binary_part(line, close_index + 5, byte_size(line) - close_index - 5)
        }

      :nomatch ->
        :not_found
    end
  end

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
       when delimiter in ["```", "~~~"], do: {delimiter, rest}

  defp fence_delimiter(_line), do: :error

  defp delimiter_tail(text, delimiter) do
    offset = byte_size(delimiter)
    binary_part(text, offset, byte_size(text) - offset)
  end

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

  defp collapse_blank_lines(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], false}, fn
      "", {acc, true} -> {acc, true}
      "", {acc, false} -> {["" | acc], true}
      line, {acc, _blank?} -> {[line | acc], false}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
