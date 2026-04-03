defmodule SpectreKinetic.RuntimeTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Registry.ETS
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime

  test "load_runtime/1 builds a persistent runtime that can plan directly" do
    registry_json = write_registry_json([email_action(), note_delete_action()])

    assert {:ok, %PlannerRuntime{} = runtime} =
             SpectreKinetic.load_runtime(registry_json: registry_json)

    assert SpectreKinetic.action_count(runtime) == 2

    assert {:ok, action} =
             SpectreKinetic.plan(
               runtime,
               ~s(SEND OUTBOUND EMAIL WITH: TO=user@test.com SUBJECT="Hello" BODY="World")
             )

    assert action.selected_tool == "Dynamic.Email.send/3"
    assert action.status == :ok

    assert action.args == %{
             "to" => "user@test.com",
             "subject" => "Hello",
             "body" => "World"
           }
  end

  test "runtime mutation APIs return updated runtimes" do
    registry_json = write_registry_json([email_action()])
    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: registry_json)

    assert {:ok, runtime} = SpectreKinetic.add_action(runtime, note_delete_action())
    assert SpectreKinetic.action_count(runtime) == 2

    assert {:ok, action} = SpectreKinetic.plan(runtime, "DELETE NOTE ENTRY WITH: ID=note-42")
    assert action.selected_tool == "Dynamic.Note.delete/1"

    assert {:ok, true, runtime} =
             SpectreKinetic.delete_action(runtime, "Dynamic.Note.delete/1")

    assert SpectreKinetic.action_count(runtime) == 1
  end

  test "runtime reload swaps registry contents" do
    email_json = write_registry_json([email_action()])
    notes_json = write_registry_json([note_delete_action()])

    {:ok, runtime} = SpectreKinetic.load_runtime(registry_json: email_json)
    assert SpectreKinetic.action_count(runtime) == 1

    assert {:ok, runtime} = SpectreKinetic.reload_registry(runtime, notes_json)
    assert SpectreKinetic.action_count(runtime) == 1

    assert {:ok, action} = SpectreKinetic.plan(runtime, "DELETE NOTE ENTRY WITH: ID=note-1")
    assert action.selected_tool == "Dynamic.Note.delete/1"
  end

  test "ETS registry backend can be used directly without the compatibility server" do
    {:ok, registry} = ETS.new()

    try do
      assert {:ok, registry} = ETS.add_action(registry, email_action())
      assert ETS.action_count(registry) == 1
      assert ETS.get_action(registry, "Dynamic.Email.send/3")["name"] == "send"
      assert ETS.resolve_alias(registry, "recipient") == [{"Dynamic.Email.send/3", "to"}]

      assert {:ok, registry} =
               ETS.put_embedding(registry, "Dynamic.Email.send/3", Nx.tensor([1.0, 0.0, 0.0]))

      assert {matrix, ids} = ETS.embedding_matrix(registry)
      assert ids == ["Dynamic.Email.send/3"]
      assert Nx.shape(matrix) == {1, 3}
    after
      ETS.close(registry)
    end
  end

  defp write_registry_json(actions) do
    path =
      Path.join(System.tmp_dir!(), "spectre_runtime_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{"actions" => actions}))
    path
  end

  defp email_action do
    %{
      "id" => "Dynamic.Email.send/3",
      "module" => "Dynamic.Email",
      "name" => "send",
      "arity" => 3,
      "doc" => "Send an outbound email message",
      "spec" => "send(to, subject, body)",
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
      ],
      "examples" => [
        "SEND OUTBOUND EMAIL WITH: TO=user@example.com SUBJECT=\"Status\" BODY=\"Report\""
      ]
    }
  end

  defp note_delete_action do
    %{
      "id" => "Dynamic.Note.delete/1",
      "module" => "Dynamic.Note",
      "name" => "delete",
      "arity" => 1,
      "doc" => "Delete a note entry identified by id",
      "spec" => "delete(id)",
      "args" => [
        %{"name" => "id", "type" => "String.t()", "required" => true, "aliases" => ["note_id"]}
      ],
      "examples" => ["DELETE NOTE ENTRY WITH: ID=note-1"]
    }
  end
end
