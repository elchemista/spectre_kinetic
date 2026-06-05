defmodule SpectreKinetic.Parser do
  @moduledoc """
  Lightweight AL normalization and validation.

  This module focuses only on AL cleanup and lightweight extraction. It:

  - unwraps common LLM wrappers like `AL:`, `<al>...</al>`, and fenced `al` blocks
  - normalizes whitespace
  - validates that a candidate looks like usable AL
  - extracts loose metadata and literal `KEY=value` args for Elixir-side helpers

  It does not perform retrieval or final slot-to-param planning.
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

  alias SpectreKinetic.Parser.Args
  alias SpectreKinetic.Parser.Wrappers

  @doc """
  Normalizes AL text by unwrapping common LLM wrappers and collapsing whitespace.
  """
  @spec normalize(binary()) :: {:ok, binary()} | {:error, validation_error()}
  def normalize(al_text) when is_binary(al_text) do
    Wrappers.normalize(al_text)
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
      {head, with_part} = Args.split_with_section(normalized)
      {verb, object} = parse_verb_object(head)
      args_source = with_part || normalized

      %{
        al: normalized,
        verb: verb,
        object: object,
        args: Args.parse(args_source)
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

  defp validate_normalized(""), do: {:error, :empty_al}

  defp validate_normalized(normalized) do
    normalized
    |> first_token()
    |> validate_first_token()
  end

  defp validate_first_token(nil), do: {:error, :empty_al}
  defp validate_first_token(<<char, _::binary>>) when char in ?A..?Z or char in ?a..?z, do: :ok
  defp validate_first_token(_token), do: {:error, :invalid_al_verb}

  defp parse_verb_object(head) do
    head
    |> String.trim()
    |> String.split(" ", parts: 2)
    |> parse_verb_object_parts()
  end

  defp parse_verb_object_parts([verb]), do: {String.upcase(verb), nil}

  defp parse_verb_object_parts([verb, rest]) do
    {String.upcase(verb), normalize_object(rest)}
  end

  defp normalize_object(rest) do
    rest
    |> String.trim()
    |> trim_terminal_punctuation()
    |> normalize_object_result()
  end

  defp normalize_object_result(""), do: nil
  defp normalize_object_result(object), do: object

  defp first_token(text) do
    text
    |> String.split(" ", parts: 2, trim: true)
    |> List.first()
  end

  defp trim_terminal_punctuation(text), do: String.trim(text, " ;,.")
end
