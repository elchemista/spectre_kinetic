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

  test "from_plan repairs common body and url aliases at the public boundary" do
    plan = %{
      "status" => "MISSING_ARGS",
      "selected_tool" => "Dynamic.Webhook.send/2",
      "args" => %{},
      "missing" => ["url", "body"],
      "notes" => ["unmatched slots: [\"link\", \"message\"]"]
    }

    action =
      Action.from_plan(
        ~s(SEND WEBHOOK WITH: LINK="https://example.com/hook" MESSAGE="deploy failed"),
        plan
      )

    assert action.status == :ok
    assert action.args["url"] == "https://example.com/hook"
    assert action.args["body"] == "deploy failed"
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

  test "from_plan includes classifier enrichment fields" do
    plan = %{
      "status" => "needs_confirmation",
      "selected_tool" => "Dynamic.Email.send/2",
      "args" => %{"to" => "dev@example.com"},
      "missing" => [],
      "classifier_results" => %{
        safety_risk: %{risk: :external_side_effect, requires_confirmation: true}
      },
      "warnings" => ["planned action has external_side_effect risk"],
      "halted?" => true
    }

    action = Action.from_plan("SEND EMAIL TO=dev@example.com", plan)

    assert action.status == :needs_confirmation
    assert action.classifier_results.safety_risk.risk == :external_side_effect
    assert action.warnings == ["planned action has external_side_effect risk"]
    assert action.halted?
  end

  test "from_plan rejects unknown string statuses without creating atoms" do
    action = Action.from_plan("SEND EMAIL", %{"status" => "UNEXPECTED_STATUS"})

    assert action.status == :error
  end
end
