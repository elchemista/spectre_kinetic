defmodule SpectreKinetic.ActionTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Action

  test "from_plan never repairs missing arguments after policy evaluation" do
    plan = %{
      "status" => "MISSING_ARGS",
      "selected_tool" => "vext.action.send_email",
      "args" => %{},
      "missing" => ["to"],
      "notes" => ["unmatched slots: [\"to\"]", "other note"]
    }

    action = Action.from_plan("SEND EMAIL TO=yuriy.zhar@gmail.com", plan)

    assert action.status == :missing_args
    assert action.args == %{}
    assert action.missing == ["to"]
    assert action.notes == ["unmatched slots: [\"to\"]", "other note"]
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

    assert action.status == :missing_args
    assert action.args == %{}
    assert action.missing == ["to"]
    assert action.notes == ["unmatched slots: [\"recipient\"]"]
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

    assert action.status == :missing_args
    assert action.args == %{}
    assert action.missing == ["url", "body"]
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

    assert action.status == :missing_args
    assert action.args == %{}
    assert action.notes == ["unmatched slots: [\"recipient\", \"body\"]"]
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

  test "from_plan does not repair arguments rejected by schema validation" do
    plan = %{
      "status" => "MISSING_ARGS",
      "selected_tool" => "Counter.set/1",
      "args" => %{},
      "missing" => ["count"],
      "invalid" => [%{name: "count", expected_type: "integer()", reason: :type_mismatch}],
      "notes" => ["invalid type for count: expected integer()"]
    }

    action = Action.from_plan("SET COUNT WITH: COUNT=many", plan)

    assert action.status == :missing_args
    assert action.args == %{}

    assert action.invalid == [
             %{name: "count", expected_type: "integer()", reason: :type_mismatch}
           ]

    assert action.missing == ["count"]
  end

  test "from_plan argument repair never upgrades classifier or policy safety decisions" do
    for status <- ~w(rejected needs_confirmation needs_clarification) do
      plan = %{
        "status" => status,
        "selected_tool" => "vext.action.send_email",
        "args" => %{},
        "missing" => ["to"],
        "notes" => ["unmatched slots: [\"recipient\"]"]
      }

      action = Action.from_plan("SEND EMAIL RECIPIENT=ops@example.com", plan)

      assert action.status == String.to_existing_atom(status)
      assert action.args == %{}
      assert action.missing == ["to"]
      assert action.notes == ["unmatched slots: [\"recipient\"]"]
    end
  end

  test "from_plan preserves restrictive atom statuses while repairing arguments" do
    plan = %{
      "status" => :rejected,
      "selected_tool" => "vext.action.send_email",
      "args" => %{},
      "missing" => ["to"]
    }

    action = Action.from_plan("SEND EMAIL RECIPIENT=ops@example.com", plan)

    assert action.status == :rejected
    assert action.args == %{}
    assert action.missing == ["to"]
  end

  test "from_plan rejects unknown string statuses without creating atoms" do
    action = Action.from_plan("SEND EMAIL", %{"status" => "UNEXPECTED_STATUS"})

    assert action.status == :error
  end

  test "from_plan preserves planner error diagnostics" do
    action =
      Action.from_plan("SEND EMAIL", %{
        "status" => "error",
        "error" => {:registry_backend_failed, :lookup}
      })

    assert action.status == :error
    assert action.error == {:registry_backend_failed, :lookup}
  end
end
