defmodule SpectreKinetic.ALExtractor do
  @moduledoc """
  Extracts AL (Action Language) statements from LLM output text.

  AL lines follow the pattern:
    AL: VERB [OBJECT] [WITH: KEY="value" KEY2="value2"]

  Returns {clean_text, [al_statements]} where clean_text has AL lines removed.
  Skips AL lines inside fenced code blocks and blockquotes to prevent prompt injection.
  """

  @doc """
  Extracts AL statements from text, returning `{clean_text, [al_statements]}`.

  Only processes assistant output. AL lines are removed from clean_text.
  Lines inside fenced code blocks (``` ... ```) and blockquotes (>) are preserved
  in clean_text but never parsed as AL to block prompt-injection attempts.
  """
  @spec extract(binary()) :: {binary(), [binary()]}
  def extract(text) when is_binary(text) do
    lines = String.split(text, "\n")

    {clean_lines_rev, al_rev, _in_block} =
      Enum.reduce(lines, {[], [], false}, fn line, {clean, als, in_block} ->
        trimmed = String.trim_leading(line)

        cond do
          String.starts_with?(trimmed, "```") ->
            # Toggle code block fence; preserve the fence line
            {[line | clean], als, !in_block}

          in_block ->
            # Inside code block — preserve, never parse as AL
            {[line | clean], als, true}

          String.starts_with?(trimmed, ">") ->
            # Blockquote — preserve, never parse as AL
            {[line | clean], als, false}

          true ->
            case Regex.run(~r/^AL:\s*(.+)$/i, trimmed) do
              [_, al_text] ->
                # AL line: strip from clean_text, collect the statement
                {clean, [String.trim(al_text) | als], false}

              nil ->
                {[line | clean], als, false}
            end
        end
      end)

    clean_text =
      clean_lines_rev
      |> Enum.reverse()
      |> Enum.join("\n")
      |> collapse_blank_lines()
      |> String.trim()

    {clean_text, Enum.reverse(al_rev)}
  end

  def extract(_), do: {"", []}

  @doc """
  Parses an AL statement into `%{verb: binary(), object: binary() | nil, args: map()}`.

  Returns `{:error, :invalid_al}` for unparseable or empty input.

  Keys in `args` are uppercased. Values are preserved as-is.
  Supports both double and single quoted values, and bare (unquoted) values.
  """
  @spec parse_al(binary()) ::
          %{verb: binary(), object: binary() | nil, args: map()} | {:error, :invalid_al}
  def parse_al(al_text) when is_binary(al_text) do
    trimmed = String.trim(al_text)

    if trimmed == "" do
      {:error, :invalid_al}
    else
      # Split on WITH keyword (WITH:, WITH , with:, With, etc.)
      case Regex.split(~r/\s+WITH:?\s+/i, trimmed, parts: 2) do
        [head, with_part] ->
          {verb, object} = parse_verb_object(String.upcase(head))
          args = parse_args(with_part)
          %{verb: verb, object: object, args: args}

        [head] ->
          # No WITH keyword — check if KEY=value args follow the verb+object directly.
          # Find the first KEY=value pattern and split there.
          case Regex.run(~r/\A(.*?)\s+([A-Za-z][A-Za-z0-9_]*\s*=)/s, head) do
            [_, verb_obj, _first_key] when verb_obj != "" ->
              {verb, object} = parse_verb_object(String.upcase(verb_obj))
              args_start = byte_size(verb_obj) + 1
              args_part = binary_part(head, args_start, byte_size(head) - args_start)
              args = parse_args(args_part)
              %{verb: verb, object: object, args: args}

            _ ->
              {verb, object} = parse_verb_object(String.upcase(head))
              %{verb: verb, object: object, args: %{}}
          end
      end
    end
  end

  def parse_al(_), do: {:error, :invalid_al}

  # ---

  @spec parse_verb_object(binary()) :: {binary(), binary() | nil}
  defp parse_verb_object(head) do
    case String.split(String.trim(head), " ", parts: 2) do
      [verb] ->
        {verb, nil}

      [verb, rest] ->
        object = rest |> String.trim() |> strip_punctuation()
        {verb, if(object == "", do: nil, else: object)}
    end
  end

  # Matches KEY="value", KEY='value', or KEY=bare_value (keys normalized to uppercase)
  @spec parse_args(binary()) :: map()
  defp parse_args(with_part) do
    Regex.scan(
      ~r/([A-Za-z][A-Za-z0-9_]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,;]+))/,
      with_part
    )
    |> Enum.reduce(%{}, fn match, acc ->
      key = String.upcase(Enum.at(match, 1, ""))

      value =
        cond do
          Enum.at(match, 2, "") != "" -> Enum.at(match, 2)
          Enum.at(match, 3, "") != "" -> Enum.at(match, 3)
          Enum.at(match, 4, "") != "" -> strip_punctuation(Enum.at(match, 4))
          true -> nil
        end

      if key != "" and not is_nil(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  @spec strip_punctuation(binary()) :: binary()
  defp strip_punctuation(str), do: String.trim(str, ";,.")

  @spec collapse_blank_lines(binary()) :: binary()
  defp collapse_blank_lines(text), do: Regex.replace(~r/\n{3,}/, text, "\n\n")
end
