defmodule SpectreKinetic.ParserTest do
  use ExUnit.Case, async: true

  @explicit_fields [
    {"TO", "yuriy.zhar@gmail.com"},
    {"RECIPIENT", "ops@example.com"},
    {"EMAIL", "alerts@example.com"},
    {"PHONE", "+15551234567"},
    {"SUBJECT", "invoice-42"},
    {"BODY", "hello-world"},
    {"TITLE", "launch-note"},
    {"PATH", "/var/log/app.log"},
    {"FILE", "README.md"},
    {"URL", "https://example.com/api"},
    {"REPO", "acme/widgets"},
    {"METHOD", "POST"},
    {"AMOUNT", "5000"},
    {"CURRENCY", "usd"}
  ]

  @loose_fields [
    {"TO", "yuriy.zhar@gmail.com"},
    {"RECIPIENT", "ops@example.com"},
    {"PHONE", "+15551234567"},
    {"SUBJECT", "invoice-42"},
    {"BODY", "hello-world"},
    {"TITLE", "launch-note"},
    {"PATH", "/var/log/app.log"},
    {"FILE", "README.md"},
    {"URL", "https://example.com/api"},
    {"REPO", "acme/widgets"},
    {"METHOD", "POST"},
    {"AMOUNT", "5000"}
  ]

  @explicit_builders [
    :with_equals,
    :bare_equals,
    :lower_with_equals,
    :with_colon,
    :with_single_quote
  ]

  @loose_builders [:bare_space, :with_space, :lower_with_space, :punctuated_space]

  test "parse_al handles at least 100 AL argument examples" do
    examples = parser_examples()

    assert length(examples) >= 100

    Enum.each(examples, fn {al, expected_key, expected_value} ->
      assert %{args: args} = SpectreKinetic.parse_al(al)

      assert Map.get(args, expected_key) == expected_value,
             "expected #{inspect(expected_key)}=#{inspect(expected_value)} for AL #{inspect(al)}, got #{inspect(args)}"
    end)
  end

  test "parse_al extracts explicit and loose inline args for email recipient" do
    assert %{args: %{"TO" => "yuriy.zhar@gmail.com"}} =
             SpectreKinetic.parse_al("SEND ME EMAIL TO=yuriy.zhar@gmail.com")

    assert %{args: %{"TO" => "yuriy.zhar@gmail.com"}} =
             SpectreKinetic.parse_al("SEND ME EMAIL TO: yuriy.zhar@gmail.com")

    assert %{args: %{"TO" => "yuriy.zhar@gmail.com"}} =
             SpectreKinetic.parse_al("SEND ME EMAIL to yuriy.zhar@gmail.com")
  end

  defp parser_examples do
    explicit_examples =
      for {key, value} <- @explicit_fields,
          builder <- @explicit_builders do
        build_explicit_example(builder, key, value)
      end

    loose_examples =
      for {key, value} <- @loose_fields,
          builder <- @loose_builders do
        build_loose_example(builder, key, value)
      end

    explicit_examples ++ loose_examples
  end

  defp build_explicit_example(:with_equals, key, value),
    do: {"SEND TEST WITH: #{key}=#{value}", key, value}

  defp build_explicit_example(:bare_equals, key, value),
    do: {"SEND TEST #{key}=#{value}", key, value}

  defp build_explicit_example(:lower_with_equals, key, value),
    do: {"send test with: #{String.downcase(key)}=#{value}", key, value}

  defp build_explicit_example(:with_colon, key, value),
    do: {"SEND TEST WITH: #{key}: #{value}", key, value}

  defp build_explicit_example(:with_single_quote, key, value),
    do: {"SEND TEST WITH: #{key}='#{value}'", key, value}

  defp build_loose_example(:bare_space, key, value),
    do: {"SEND TEST #{key} #{value}", key, value}

  defp build_loose_example(:with_space, key, value),
    do: {"SEND TEST WITH #{key} #{value}", key, value}

  defp build_loose_example(:lower_with_space, key, value),
    do: {"send test with: #{String.downcase(key)} #{value}", key, value}

  defp build_loose_example(:punctuated_space, key, value),
    do: {"SEND TEST, #{key} #{value};", key, value}
end
