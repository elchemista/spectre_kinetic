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

  alias SpectreKinetic.Extractor.Fences
  alias SpectreKinetic.Extractor.Tags

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
    if String.valid?(text) do
      do_scan(text)
    else
      %{clean_text: "", entries: [invalid_entry(text, :invalid_al)]}
    end
  end

  def scan(_), do: %{clean_text: "", entries: []}

  defp do_scan(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce(%{mode: :normal, clean_lines: [], entries: []}, &consume_line/2)
    |> finalize_scan()
  end

  # We build lists backwards because appending line-by-line is how tiny scripts
  # become tiny regrets. The public result is put back in order at the boundary.
  defp consume_line(line, %{mode: :normal} = state) do
    trimmed = String.trim_leading(line)
    fence_candidate = drop_list_prefix(trimmed)

    case Fences.parse_open(fence_candidate) do
      {:al_inline, _raw} ->
        handle_normal_line(line, state)

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
    quote_prefix = raw_parts(parts) <> "\n"

    case Fences.parse_close(line, delimiter, quote_prefix) do
      {:close, before_close, after_close} ->
        %{state | mode: :normal}
        |> add_entry(multiline_raw(parts, before_close))
        |> continue_after_close(after_close)

      :continue ->
        %{state | mode: {:al_fence, delimiter, [line | parts]}}
    end
  end

  defp consume_line(line, %{mode: {:al_tag, parts}} = state) do
    quote_prefix = raw_parts(parts) <> "\n"

    case Tags.split_close(line, quote_prefix) do
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
      if Fences.plain_close?(line, delimiter) do
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
    segments = ordered_wrapper_segments(line)
    clean_line = remove_wrapper_segments(line, segments)

    state =
      segments
      |> Enum.filter(&(&1.kind == :closed))
      |> Enum.map(& &1.raw)
      |> then(&append_raw_entries(state, &1))

    case Enum.find(segments, &(&1.kind == :open)) do
      nil ->
        keep_prefixed_al_or_clean(state, clean_line)

      %{raw: raw} ->
        state
        |> keep_clean(clean_line)
        |> Map.put(:mode, {:al_tag, [raw]})
    end
  end

  defp ordered_wrapper_segments(line) do
    (Tags.locate_segments(line) ++ Fences.locate_inline_segments(line))
    |> Enum.sort_by(&{&1.start, -&1.stop})
    |> Enum.reduce({[], 0}, fn segment, {segments, cursor} ->
      if segment.start < cursor do
        {segments, cursor}
      else
        {[segment | segments], segment.stop}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp remove_wrapper_segments(line, segments) do
    {parts, cursor} =
      Enum.reduce(segments, {[], 0}, fn segment, {parts, cursor} ->
        clean_size = segment.start - cursor
        clean_part = binary_part(line, cursor, clean_size)
        {[clean_part | parts], segment.stop}
      end)

    tail = binary_part(line, cursor, byte_size(line) - cursor)

    clean_line =
      [tail | parts]
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    if segments == [], do: clean_line, else: remove_empty_list_prefix(clean_line)
  end

  defp remove_empty_list_prefix(line) do
    trimmed = String.trim(line)

    if drop_list_prefix(trimmed) == "", do: "", else: line
  end

  defp append_raw_entries(state, raws), do: Enum.reduce(raws, state, &add_entry(&2, &1))

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

  defp raw_parts(parts), do: parts |> Enum.reverse() |> Enum.join("\n")

  defp build_entry(raw) do
    case SpectreKinetic.Parser.validate(raw) do
      {:ok, al} -> %{raw: raw, al: al, error: nil}
      {:error, reason} -> invalid_entry(raw, reason)
    end
  end

  defp invalid_entry(raw, reason), do: %{raw: raw, al: nil, error: reason}
  defp entry_to_actions(%{al: nil}), do: []
  defp entry_to_actions(%{al: al}), do: [al]

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
