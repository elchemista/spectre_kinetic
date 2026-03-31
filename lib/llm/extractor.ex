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

  @spec extract(binary()) :: {binary(), [binary()]}
  def extract(text) when is_binary(text) do
    result = scan(text)
    {result.clean_text, Enum.flat_map(result.entries, &entry_to_actions/1)}
  end

  def extract(_), do: {"", []}

  @spec scan(binary()) :: scan_result()
  def scan(text) when is_binary(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce(%{mode: :normal, clean_lines: [], entries: []}, &consume_line/2)
    |> finalize_scan()
  end

  def scan(_), do: %{clean_text: "", entries: []}

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
        raw =
          [parts, [before_close]]
          |> List.flatten()
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")

        %{state | mode: :normal}
        |> add_entry(raw)
        |> continue_after_close(after_close)

      :continue ->
        %{state | mode: {:al_fence, delimiter, parts ++ [line]}}
    end
  end

  defp consume_line(line, %{mode: {:al_tag, parts}} = state) do
    case split_al_close(line) do
      {:ok, before_close, after_close} ->
        raw =
          [parts, [before_close]]
          |> List.flatten()
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")

        %{state | mode: :normal}
        |> add_entry(raw)
        |> handle_normal_line(after_close)

      :not_found ->
        %{state | mode: {:al_tag, parts ++ [line]}}
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
    build_result(
      clean_lines,
      entries ++ [invalid_entry(Enum.join(parts, "\n"), :unterminated_al_fence)]
    )
  end

  defp finalize_scan(%{mode: {:al_tag, parts}, clean_lines: clean_lines, entries: entries}) do
    build_result(
      clean_lines,
      entries ++ [invalid_entry(Enum.join(parts, "\n"), :unterminated_al_tag)]
    )
  end

  defp finalize_scan(%{clean_lines: clean_lines, entries: entries}) do
    build_result(clean_lines, entries)
  end

  defp build_result(clean_lines, entries) do
    %{
      clean_text:
        clean_lines
        |> Enum.join("\n")
        |> collapse_blank_lines()
        |> String.trim(),
      entries: entries
    }
  end

  defp handle_normal_line(line, state) do
    case extract_tagged_segments(line, [], []) do
      {:tag_open, clean_parts, parts} ->
        state
        |> keep_clean(IO.iodata_to_binary(Enum.reverse(clean_parts)))
        |> Map.put(:mode, {:al_tag, [IO.iodata_to_binary(Enum.reverse(parts))]})

      {:ok, clean_parts, entries} ->
        clean_line = IO.iodata_to_binary(Enum.reverse(clean_parts))

        {:ok, clean_parts, inline_entries} = extract_inline_fence_segments(clean_line, [], [])
        clean_line = IO.iodata_to_binary(Enum.reverse(clean_parts))

        state =
          (entries ++ inline_entries)
          |> Enum.reduce(state, &append_entry/2)

        case al_prefixed_candidate(clean_line) do
          {:ok, raw} -> state |> add_entry(raw) |> keep_clean("")
          :not_al -> keep_clean(state, clean_line)
        end
    end
  end

  defp extract_tagged_segments("", clean_parts, entries),
    do: {:ok, clean_parts, Enum.reverse(entries)}

  defp extract_tagged_segments(line, clean_parts, entries) do
    case split_al_open(line) do
      :not_found ->
        {:ok, [line | clean_parts], Enum.reverse(entries)}

      {:ok, before, inside_open} ->
        case split_al_close(inside_open) do
          {:ok, raw, after_close} ->
            extract_tagged_segments(after_close, [before | clean_parts], [
              build_entry(raw) | entries
            ])

          :not_found ->
            {:tag_open, [before | clean_parts], [inside_open]}
        end
    end
  end

  defp extract_inline_fence_segments("", clean_parts, entries),
    do: {:ok, clean_parts, Enum.reverse(entries)}

  defp extract_inline_fence_segments(line, clean_parts, entries) do
    case next_inline_fence(line) do
      :not_found ->
        {:ok, [line | clean_parts], Enum.reverse(entries)}

      {index, delimiter} ->
        before = binary_part(line, 0, index)
        rest = binary_part(line, index, byte_size(line) - index)

        case parse_inline_al_fence(rest, delimiter) do
          {:ok, raw, after_close} ->
            extract_inline_fence_segments(after_close, [before | clean_parts], [
              build_entry(raw) | entries
            ])

          :not_al ->
            {:ok, [line | clean_parts], Enum.reverse(entries)}

          :not_inline ->
            {:ok, [line | clean_parts], Enum.reverse(entries)}
        end
    end
  end

  defp continue_after_close(state, ""), do: keep_clean(state, "")
  defp continue_after_close(state, after_close), do: handle_normal_line(after_close, state)

  defp keep_clean(state, line), do: %{state | clean_lines: state.clean_lines ++ [line]}

  defp add_entry(state, raw), do: append_entry(build_entry(raw), state)
  defp append_entry(entry, state), do: %{state | entries: state.entries ++ [entry]}

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
        case split_first_token(String.trim_leading(rest)) do
          {language, content} ->
            language = String.downcase(language)

            if language in ["al", "action", "action-language"] do
              parse_fence_body(delimiter, content)
            else
              {:plain_open, delimiter}
            end

          :error ->
            {:plain_open, delimiter}
        end

      :error ->
        :not_a_fence
    end
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
        case split_first_token(String.trim_leading(after_delimiter)) do
          {language, content} ->
            language = String.downcase(language)

            if language in ["al", "action", "action-language"] do
              case split_inline_fence_close(content, delimiter) do
                {:ok, body, after_close} -> {:ok, body, after_close}
                :not_found -> :not_inline
              end
            else
              :not_al
            end

          :error ->
            :not_al
        end

      :error ->
        :not_al
    end
  end

  defp parse_fence_close(line, delimiter) do
    trimmed = String.trim_leading(line)

    cond do
      trimmed == delimiter ->
        {:close, "", ""}

      String.starts_with?(trimmed, delimiter) ->
        {:close, "",
         String.trim_leading(String.slice(trimmed, byte_size(delimiter)..-1//1) || "")}

      true ->
        :continue
    end
  end

  defp plain_fence_close?(line, delimiter) do
    String.starts_with?(String.trim_leading(line), delimiter)
  end

  defp al_prefixed_candidate(line) do
    line
    |> String.trim_leading()
    |> drop_list_prefix()
    |> case do
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
      "", {acc, false} -> {acc ++ [""], true}
      line, {acc, _blank?} -> {acc ++ [line], false}
    end)
    |> elem(0)
    |> Enum.join("\n")
  end
end
