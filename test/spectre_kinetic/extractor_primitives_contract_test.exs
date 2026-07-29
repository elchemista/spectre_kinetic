defmodule SpectreKinetic.ExtractorPrimitivesContractTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Extractor.Fences
  alias SpectreKinetic.Extractor.Tags

  describe "Markdown fence grammar" do
    test "classifies plain, inline, and multiline fences without guessing languages" do
      assert Fences.parse_open("```") == {:plain_open, "```"}
      assert Fences.parse_open("```json {}") == {:plain_open, "```"}
      assert Fences.parse_open("```AL SEND EMAIL``` trailing") == {:al_inline, "SEND EMAIL"}
      assert Fences.parse_open("~~~action SEND EMAIL") == {:al_open, "~~~", "SEND EMAIL"}
      assert Fences.parse_open("~~~action-language") == {:al_open, "~~~", ""}
      assert Fences.parse_open("``al SEND EMAIL") == :not_a_fence
    end

    test "only closes a fence outside quoted AL data and returns trailing prose" do
      assert Fences.parse_close("  ```  explanation", "```") ==
               {:close, "", "explanation"}

      assert Fences.parse_close("not a close", "```") == :continue
      assert Fences.parse_close("```", "```", "\"unterminated") == :continue

      assert Fences.plain_close?("  ~~~ trailing", "~~~")
      refute Fences.plain_close?("text ~~~", "~~~")
    end

    test "extracts multiple inline AL blocks while preserving human text" do
      line =
        "before ```al SEND EMAIL``` middle ~~~action DELETE MESSAGE~~~ after"

      assert Fences.extract_inline_segments(line) ==
               {:ok, "before  middle  after", ["SEND EMAIL", "DELETE MESSAGE"]}

      assert Fences.extract_inline_segments("ordinary prose") ==
               {:ok, "ordinary prose", []}

      # An ordinary code span is data, not permission to scan through it as AL.
      plain = "```json {\"example\":\"AL\"}``` then ```al SEND EMAIL```"
      assert Fences.extract_inline_segments(plain) == {:ok, plain, []}
    end

    test "locates AL after ordinary code spans and stops at an unterminated AL fence" do
      line =
        "```json {}``` then ```al SEND EMAIL``` and ~~~action DELETE MESSAGE~~~"

      assert [
               %{kind: :closed, raw: "SEND EMAIL", start: first_start, stop: first_stop},
               %{kind: :closed, raw: "DELETE MESSAGE", start: second_start, stop: second_stop}
             ] = Fences.locate_inline_segments(line)

      assert first_start < first_stop
      assert first_stop < second_start
      assert second_start < second_stop

      assert Fences.locate_inline_segments("```json never closes") == []
      assert Fences.locate_inline_segments("before ```al SEND EMAIL") == []
    end
  end

  describe "AL tag grammar" do
    test "extracts repeated, case-insensitive tags and preserves surrounding prose" do
      line = ~S(before <AL role="tool">SEND EMAIL</AL> middle <al>DELETE MESSAGE</al> after)

      assert Tags.extract_segments(line) ==
               {:ok, "before  middle  after", ["SEND EMAIL", "DELETE MESSAGE"]}

      assert Tags.extract_segments("ordinary prose") == {:ok, "ordinary prose", []}
      assert Tags.extract_segments("") == {:ok, "", []}
    end

    test "reports an open tag so the outer scanner can carry multiline state" do
      assert Tags.extract_segments("before <al source=\"model\">SEND") ==
               {:tag_open, "before ", "SEND"}
    end

    test "ignores quoted close examples and splits at the first structural close" do
      line = ~S(SEND MESSAGE WITH: BODY="literal </al> text" </al> trailing)

      assert {:ok, raw, " trailing"} = Tags.split_close(line)
      assert raw == ~S(SEND MESSAGE WITH: BODY="literal </al> text" )
      assert Tags.split_close(~S(BODY="</al>")) == :not_found
    end

    test "locates closed and open tags in source order" do
      line = "x <al>ONE</al> y <AL kind=\"next\">TWO</AL> z"

      assert [
               %{kind: :closed, raw: "ONE", start: first_start, stop: first_stop},
               %{kind: :closed, raw: "TWO", start: second_start, stop: second_stop}
             ] = Tags.locate_segments(line)

      assert first_start < first_stop
      assert first_stop < second_start
      assert second_start < second_stop

      assert [%{kind: :open, raw: "THREE"}] =
               Tags.locate_segments("prose <al>THREE")

      assert Tags.locate_segments(~S("<al>QUOTED</al>")) == []
    end
  end
end
