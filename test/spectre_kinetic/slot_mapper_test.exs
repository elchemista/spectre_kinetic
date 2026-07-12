defmodule SpectreKinetic.Planner.SlotMapperTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.SlotMapper

  describe "map_slots/2" do
    test "exact name match" do
      parsed = %{"TO" => "user@example.com", "SUBJECT" => "Hello", "BODY" => "World"}
      result = SlotMapper.map_slots(parsed, email_action())

      assert result.args == %{"to" => "user@example.com", "subject" => "Hello", "body" => "World"}
      assert result.missing == []
      assert_in_delta result.mapping_score, 1.0, 0.001
    end

    test "alias match" do
      parsed = %{"RECIPIENT" => "user@example.com", "TITLE" => "Hello", "MESSAGE" => "World"}
      result = SlotMapper.map_slots(parsed, email_action())

      assert result.args == %{"to" => "user@example.com", "subject" => "Hello", "body" => "World"}
      assert result.missing == []
    end

    test "reports missing required args" do
      parsed = %{"TO" => "user@example.com"}
      result = SlotMapper.map_slots(parsed, email_action())

      assert result.args["to"] == "user@example.com"
      assert "subject" in result.missing
      assert "body" in result.missing
      assert result.mapping_score < 1.0
    end

    test "notes unmatched slots" do
      parsed = %{"TO" => "user@example.com", "SUBJECT" => "Hi", "BODY" => "Ok", "FOO" => "bar"}
      result = SlotMapper.map_slots(parsed, email_action())

      assert result.args["to"] == "user@example.com"
      assert Enum.any?(result.notes, &String.contains?(&1, "unmatched"))
    end

    test "handles empty args" do
      parsed = %{}
      action = %{"args" => []}
      result = SlotMapper.map_slots(parsed, action)

      assert result.args == %{}
      assert result.missing == []
      assert_in_delta result.mapping_score, 1.0, 0.001
    end

    test "case-insensitive matching" do
      parsed = %{"to" => "user@example.com", "Subject" => "Hello", "BODY" => "World"}
      result = SlotMapper.map_slots(parsed, email_action())

      assert result.args["to"] == "user@example.com"
      assert result.args["subject"] == "Hello"
      assert result.args["body"] == "World"
    end
  end

  describe "type-based matching" do
    test "email value matches email-typed params" do
      parsed = %{"X" => "user@example.com"}

      action = %{
        "args" => [
          %{"name" => "to", "type" => "String.t()", "required" => true, "aliases" => []}
        ]
      }

      result = SlotMapper.map_slots(parsed, action)
      assert result.args["to"] == "user@example.com"
    end

    test "phone value matches phone-typed params" do
      parsed = %{"X" => "+1555010001"}

      action = %{
        "args" => [
          %{"name" => "phone", "type" => "String.t()", "required" => true, "aliases" => []}
        ]
      }

      result = SlotMapper.map_slots(parsed, action)
      assert result.args["phone"] == "+1555010001"
    end
  end

  describe "schema type enforcement" do
    test "coerces scalar AL values to declared primitive types" do
      parsed = %{"COUNT" => "42", "RATIO" => "0.5", "ENABLED" => "off"}

      action = %{
        "args" => [
          %{"name" => "count", "type" => "pos_integer()", "required" => true},
          %{"name" => "ratio", "type" => "float()", "required" => true},
          %{"name" => "enabled", "type" => "boolean()", "required" => true}
        ]
      }

      result = SlotMapper.map_slots(parsed, action)

      assert result.args == %{"count" => 42, "ratio" => 0.5, "enabled" => false}
      assert result.invalid == []
      assert result.missing == []
    end

    test "removes invalid values and keeps required arguments missing" do
      parsed = %{"COUNT" => "many", "ENABLED" => false}

      action = %{
        "args" => [
          %{"name" => "count", "type" => "integer()", "required" => true},
          %{"name" => "enabled", "type" => "boolean()", "required" => true}
        ]
      }

      result = SlotMapper.map_slots(parsed, action)

      assert result.args == %{"enabled" => false}
      assert result.invalid == [%{name: "count", expected_type: "integer()"}]
      assert result.missing == ["count"]
      assert Enum.any?(result.notes, &String.contains?(&1, "invalid type for count"))
    end

    test "validates dates and URI values without changing their JSON shape" do
      action = %{
        "args" => [
          %{"name" => "due", "type" => "Date.t()", "required" => true},
          %{"name" => "url", "type" => "URI.t()", "required" => true}
        ]
      }

      result =
        SlotMapper.map_slots(
          %{"DUE" => "2026-07-12", "URL" => "https://example.com/task"},
          action
        )

      assert result.args == %{
               "due" => "2026-07-12",
               "url" => "https://example.com/task"
             }
    end
  end

  describe "detect_value_type/1" do
    test "detects email" do
      assert SlotMapper.detect_value_type("user@example.com") == :email
    end

    test "detects phone" do
      assert SlotMapper.detect_value_type("+1-555-010-0001") == :phone
    end

    test "detects URL" do
      assert SlotMapper.detect_value_type("https://example.com") == :url
    end

    test "detects date" do
      assert SlotMapper.detect_value_type("2026-05-01") == :date
    end

    test "detects path" do
      assert SlotMapper.detect_value_type("/usr/local/bin") == :path
    end

    test "detects boolean" do
      assert SlotMapper.detect_value_type("true") == :boolean
      assert SlotMapper.detect_value_type("false") == :boolean
    end

    test "detects integer" do
      assert SlotMapper.detect_value_type("42") == :integer
    end

    test "detects float" do
      assert SlotMapper.detect_value_type("3.14") == :float
    end

    test "returns nil for plain text" do
      assert SlotMapper.detect_value_type("hello world") == nil
    end
  end

  defp email_action do
    %{
      "args" => [
        %{
          "name" => "to",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["recipient", "email"]
        },
        %{
          "name" => "subject",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["title"]
        },
        %{
          "name" => "body",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["message", "text"]
        }
      ]
    }
  end
end
