defmodule SpectreKinetic.Extractor.Tags do
  @moduledoc false

  @open_tag_pattern ~r/<al(?:\s+[^>]*)?>/iu
  @close_tag_pattern ~r/<\/al>/iu

  alias SpectreKinetic.Parser.Syntax

  @type segment :: %{
          kind: :closed | :open,
          start: non_neg_integer(),
          stop: non_neg_integer(),
          raw: binary()
        }

  # XML-ish <al> segments inside one line. The scanner handles multi-line state;
  # this module only cuts a line into clean text plus raw AL candidates.

  @spec extract_segments(binary()) ::
          {:ok, binary(), [binary()]}
          | {:tag_open, binary(), binary()}
  def extract_segments(line) do
    case extract_tagged(line, [], []) do
      {:ok, clean_parts, raws} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(clean_parts)), Enum.reverse(raws)}

      {:tag_open, clean_parts, parts} ->
        {:tag_open, IO.iodata_to_binary(Enum.reverse(clean_parts)),
         IO.iodata_to_binary(Enum.reverse(parts))}
    end
  end

  @spec locate_segments(binary()) :: [segment()]
  def locate_segments(line) when is_binary(line) do
    locate_segments(line, 0, [])
  end

  @spec split_close(binary(), binary()) :: {:ok, binary(), binary()} | :not_found
  def split_close(line, quote_prefix \\ "") do
    source = quote_prefix <> line
    line_offset = byte_size(quote_prefix)

    case Syntax.find_unquoted_regex(source, @close_tag_pattern, line_offset) do
      {source_index, close_size} ->
        close_index = source_index - line_offset

        {
          :ok,
          binary_part(line, 0, close_index),
          binary_part(
            line,
            close_index + close_size,
            byte_size(line) - close_index - close_size
          )
        }

      :nomatch ->
        :not_found
    end
  end

  defp extract_tagged("", clean_parts, raws), do: {:ok, clean_parts, raws}

  # A line can contain more than one tag. Keep walking until no opening tag is
  # left, or until an opening tag has no close and the outer scanner must carry
  # the state to the next line.
  defp extract_tagged(line, clean_parts, raws) do
    case split_open(line) do
      :not_found ->
        {:ok, [line | clean_parts], raws}

      {:ok, before, inside_open} ->
        case split_close(inside_open) do
          {:ok, raw, after_close} ->
            extract_tagged(after_close, [before | clean_parts], [raw | raws])

          :not_found ->
            {:tag_open, [before | clean_parts], [inside_open]}
        end
    end
  end

  defp split_open(line) do
    case Syntax.find_unquoted_regex(line, @open_tag_pattern) do
      {open_index, open_size} ->
        {
          :ok,
          binary_part(line, 0, open_index),
          binary_part(
            line,
            open_index + open_size,
            byte_size(line) - open_index - open_size
          )
        }

      :nomatch ->
        :not_found
    end
  end

  defp locate_segments(line, minimum_index, segments) do
    case Syntax.find_unquoted_regex(line, @open_tag_pattern, minimum_index) do
      {open_index, open_size} ->
        content_index = open_index + open_size

        case Syntax.find_unquoted_regex(line, @close_tag_pattern, content_index) do
          {close_index, close_size} ->
            stop = close_index + close_size

            segment = %{
              kind: :closed,
              start: open_index,
              stop: stop,
              raw: binary_part(line, content_index, close_index - content_index)
            }

            locate_segments(line, stop, [segment | segments])

          :nomatch ->
            segment = %{
              kind: :open,
              start: open_index,
              stop: byte_size(line),
              raw: binary_part(line, content_index, byte_size(line) - content_index)
            }

            Enum.reverse([segment | segments])
        end

      :nomatch ->
        Enum.reverse(segments)
    end
  end
end
