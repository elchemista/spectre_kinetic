defmodule SpectreKinetic.Extractor.Tags do
  @moduledoc false

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

  @spec split_close(binary()) :: {:ok, binary(), binary()} | :not_found
  def split_close(line) do
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
    lower = String.downcase(line)

    case :binary.match(lower, "<al") do
      {open_index, _size} ->
        split_open_at(line, lower, open_index)

      :nomatch ->
        :not_found
    end
  end

  # We match using a lowercase copy but slice from the original line, because
  # callers expect clean text and raw AL to preserve casing. Boring detail,
  # important result.
  defp split_open_at(line, lower, open_index) do
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
  end
end
