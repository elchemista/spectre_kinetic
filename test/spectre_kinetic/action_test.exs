defmodule SpectreKinetic.ActionTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Action

  test "from_plan removes stale unmatched slot note when exact arg is repaired" do
    plan = %{
      "status" => "MISSING_ARGS",
      "selected_tool" => "vext.action.send_email",
      "args" => %{},
      "missing" => ["to"],
      "notes" => ["unmatched slots: [\"to\"]", "other note"]
    }

    action = Action.from_plan("SEND EMAIL TO=yuriy.zhar@gmail.com", plan)

    assert action.status == :ok
    assert action.args["to"] == "yuriy.zhar@gmail.com"
    assert action.notes == ["other note"]
  end

  test "from_plan removes stale unmatched slot note when alias repairs missing arg" do
    plan = %{
      "status" => "MISSING_ARGS",
      "selected_tool" => "vext.action.send_email",
      "args" => %{},
      "missing" => ["to"],
      "notes" => ["unmatched slots: [\"recipient\"]"]
    }

    action = Action.from_plan("SEND EMAIL RECIPIENT=ops@example.com", plan)

    assert action.status == :ok
    assert action.args["to"] == "ops@example.com"
    assert action.notes == []
  end

  test "from_plan keeps unrelated unmatched slots in notes" do
    plan = %{
      "status" => "MISSING_ARGS",
      "selected_tool" => "vext.action.send_email",
      "args" => %{},
      "missing" => ["to"],
      "notes" => ["unmatched slots: [\"recipient\", \"body\"]"]
    }

    action = Action.from_plan("SEND EMAIL RECIPIENT=ops@example.com", plan)

    assert action.status == :ok
    assert action.args["to"] == "ops@example.com"
    assert action.notes == ["unmatched slots: [\"body\"]"]
  end
end
