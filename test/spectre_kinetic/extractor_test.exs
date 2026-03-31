defmodule SpectreKinetic.ExtractorTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Extractor
  alias SpectreKinetic.Parser

  test "extract/1 strips classic AL lines and keeps non-AL fences" do
    text = """
    Draft answer.
    AL: WRITE POST WITH: TITLE="Hello" TEXT='World'

    ```text
    AL: DO NOT PARSE THIS
    ```

    > AL: ALSO IGNORE THIS
    Final line.
    """

    assert {
             "Draft answer.\n\n```text\nAL: DO NOT PARSE THIS\n```\n\n> AL: ALSO IGNORE THIS\nFinal line.",
             ["WRITE POST WITH: TITLE=\"Hello\" TEXT='World'"]
           } = Extractor.extract(text)
  end

  test "extract/1 supports al tags and al fenced blocks" do
    text = """
    Before.
    <al>SEND EMAIL WITH: TO="dev@example.com" SUBJECT="Hi"</al>

    ```al
    LIST DIRECTORY WITH: PATH="/tmp"
    ```

    ```al SEND WEBHOOK WITH: URL="https://example.com/hook"```
    After.
    """

    assert {"Before.\n\nAfter.", actions} = Extractor.extract(text)

    assert actions == [
             ~s(SEND EMAIL WITH: TO="dev@example.com" SUBJECT="Hi"),
             ~s(LIST DIRECTORY WITH: PATH="/tmp"),
             ~s(SEND WEBHOOK WITH: URL="https://example.com/hook")
           ]
  end

  test "extract/1 keeps action order across mixed llm wrappers" do
    text = """
    I found four actions in the response.

    <al>SEND EMAIL</al>

    ```al
    LIST DIRECTORY WITH: PATH="/tmp"
    ```

    1. AL: CREATE TICKET WITH: TITLE="Bug"
    2. ```al SEND WEBHOOK WITH: URL="https://example.com"```
    """

    assert {_clean_text, actions} = Extractor.extract(text)

    assert actions == [
             "SEND EMAIL",
             ~s(LIST DIRECTORY WITH: PATH="/tmp"),
             ~s(CREATE TICKET WITH: TITLE="Bug"),
             ~s(SEND WEBHOOK WITH: URL="https://example.com")
           ]
  end

  test "scan/1 returns diagnostics for malformed AL wrappers" do
    result = Extractor.scan("<al>SEND EMAIL")

    assert result.entries == [
             %{raw: "SEND EMAIL", al: nil, error: :unterminated_al_tag}
           ]
  end

  test "parser parses verb, object, and mixed quoting styles" do
    assert %{
             al:
               "CREATE stripe payment link WITH: amount=5000 currency='usd' product_name=\"Widget\"",
             verb: "CREATE",
             object: "stripe payment link",
             args: %{"AMOUNT" => "5000", "CURRENCY" => "usd", "PRODUCT_NAME" => "Widget"}
           } =
             Parser.parse(
               "CREATE stripe payment link WITH: amount=5000 currency='usd' product_name=\"Widget\""
             )
  end

  test "parser validates wrappers and returns normalized AL" do
    assert {:ok, ~s(SEND EMAIL WITH: TO="dev@example.com")} =
             Parser.validate("<al> SEND EMAIL WITH: TO=\"dev@example.com\" </al>")

    assert {:ok, "SEND EMAIL"} = Parser.normalize("```al SEND EMAIL```")
    assert {:ok, "SEND EMAIL"} = Parser.normalize("<AL>SEND EMAIL</AL>")
  end

  test "parser returns an error for blank or malformed input" do
    assert {:error, :empty_al} = Parser.parse("   ")
    assert {:error, :unterminated_al_fence} = Parser.validate("```al\nSEND EMAIL")
  end
end
