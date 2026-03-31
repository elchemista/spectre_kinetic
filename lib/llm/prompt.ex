defmodule SpectreKinetic.Prompt do
  @moduledoc """
  Builds an LLM-ready prompt for zero-shot AL generation.

  The goal is to keep the LLM output easy to extract:

  - one AL instruction per block
  - stable wrapper format
  - only dictionary-backed slots and examples
  - no extra prose in the output

  The prompt follows the upstream engine semantics:

  - action matching is driven by the action text pattern
  - placeholders like `{path}` or `{package}` are valid in the action body
  - `WITH:` is valid, but not the only AL form
  - examples should be copied structurally instead of rewritten into one forced shape
  """

  alias SpectreKinetic.Dictionary

  @type output_format :: :tags | :lines

  @spec build(keyword()) :: {:ok, binary()} | {:error, term()}
  def build(opts \\ []) do
    with {:ok, dictionary} <- dictionary_from_opts(opts) do
      {:ok, render(dictionary, opts)}
    end
  end

  @spec build!(keyword()) :: binary()
  def build!(opts \\ []) do
    with {:ok, prompt} <- build(opts) do
      prompt
    else
      {:error, reason} -> raise ArgumentError, "failed to build AL prompt: #{inspect(reason)}"
    end
  end

  @spec render(Dictionary.t(), keyword()) :: binary()
  def render(%Dictionary{} = dictionary, opts \\ []) do
    output = Keyword.get(opts, :output, :tags)

    [
      intro(output),
      rules(output, opts),
      dictionary_section(dictionary, output),
      request_section(opts[:request]),
      final_instruction(output)
    ]
    |> Enum.reject(&blank_section?/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp dictionary_from_opts(opts) do
    case opts[:dictionary] do
      %Dictionary{} = dictionary -> {:ok, dictionary}
      nil -> Dictionary.build(opts)
      other -> {:error, {:invalid_dictionary, other}}
    end
  end

  defp intro(:tags) do
    """
    You translate natural-language requests into Spectre Kinetic Action Language (AL).
    Return the result as AL blocks wrapped in `<al>...</al>`.
    """
  end

  defp intro(:lines) do
    """
    You translate natural-language requests into Spectre Kinetic Action Language (AL).
    Return the result as raw `AL: ...` lines.
    """
  end

  defp rules(output, opts) do
    extra_rules =
      opts
      |> Keyword.get(:extra_rules, [])
      |> Enum.map(&("- " <> String.trim(&1)))

    [
      "Rules:",
      "- Emit one AL instruction per action, in execution order.",
      "- Use only slot names that appear in the allowed slots list.",
      "- Reuse the action patterns and wording from the dictionary examples whenever possible.",
      "- Follow the example shape exactly when possible, including action-body placeholders or `WITH:` sections.",
      "- Preserve literal values from the request exactly.",
      "- `WITH:` is optional. Use it only when the matched action pattern uses named assignments or the examples use it.",
      "- Positional AL like `INSTALL PACKAGE nginx VIA APT` or `LIST DIRECTORY /tmp` is valid when it matches the example pattern.",
      "- Use `KEY=value` assignments only for arguments that belong in a `WITH:` section.",
      "- Quote literal values when they contain spaces or punctuation.",
      "- Do not invent tools, slot names, or extra fields.",
      "- Do not explain your reasoning.",
      output_rule(output)
      | extra_rules
    ]
    |> Enum.join("\n")
  end

  defp output_rule(:tags), do: "- Output only `<al>...</al>` blocks and nothing else."
  defp output_rule(:lines), do: "- Output only `AL: ...` lines and nothing else."

  defp dictionary_section(%Dictionary{} = dictionary, output) do
    examples =
      dictionary.examples
      |> Enum.map(&format_example(&1, output))
      |> case do
        [] -> ["- none"]
        items -> Enum.map(items, &("- " <> &1))
      end

    [
      "Allowed action ids:",
      list_or_none(dictionary.action_ids),
      "Keywords:",
      list_or_none(dictionary.keywords),
      "Allowed slots:",
      list_or_none(dictionary.slots),
      "Examples:",
      Enum.join(examples, "\n")
    ]
    |> Enum.join("\n")
  end

  defp request_section(nil), do: nil
  defp request_section(""), do: nil

  defp request_section(request) when is_binary(request) do
    """
    User request:
    #{String.trim(request)}
    """
  end

  defp final_instruction(:tags) do
    "Return AL now using only `<al>...</al>` blocks."
  end

  defp final_instruction(:lines) do
    "Return AL now using only `AL: ...` lines."
  end

  defp format_example(example, :tags), do: "<al>#{String.trim(example)}</al>"
  defp format_example(example, :lines), do: "AL: #{String.trim(example)}"

  defp list_or_none([]), do: "- none"
  defp list_or_none(items), do: Enum.map_join(items, "\n", &("- " <> &1))

  defp blank_section?(nil), do: true
  defp blank_section?(""), do: true
  defp blank_section?(_), do: false
end
