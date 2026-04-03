defmodule SpectreKinetic.Planner.RegistryStoreTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.RegistryStore

  setup do
    {:ok, store} = RegistryStore.start_link(name: nil)
    {:ok, store: store}
  end

  test "starts empty", %{store: store} do
    assert RegistryStore.action_count(store) == 0
    assert RegistryStore.all_actions(store) == []
  end

  test "add and get action", %{store: store} do
    action = email_action()
    assert :ok = RegistryStore.add_action(store, action)
    assert RegistryStore.action_count(store) == 1

    loaded = RegistryStore.get_action(store, "Dynamic.Email.send/3")
    assert loaded["id"] == "Dynamic.Email.send/3"
    assert loaded["doc"] == "Send an outbound email message"
    assert length(loaded["args"]) == 3
  end

  test "delete action", %{store: store} do
    assert :ok = RegistryStore.add_action(store, email_action())
    assert RegistryStore.action_count(store) == 1

    assert {:ok, true} = RegistryStore.delete_action(store, "Dynamic.Email.send/3")
    assert RegistryStore.action_count(store) == 0

    assert {:ok, false} = RegistryStore.delete_action(store, "nonexistent")
  end

  test "resolve alias", %{store: store} do
    assert :ok = RegistryStore.add_action(store, email_action())

    # Canonical name
    results = RegistryStore.resolve_alias(store, "to")
    assert Enum.any?(results, fn {id, canonical} ->
      id == "Dynamic.Email.send/3" && canonical == "to"
    end)

    # Alias
    results = RegistryStore.resolve_alias(store, "recipient")
    assert Enum.any?(results, fn {id, canonical} ->
      id == "Dynamic.Email.send/3" && canonical == "to"
    end)

    # Unknown alias
    assert RegistryStore.resolve_alias(store, "nonexistent") == []
  end

  test "tool cards", %{store: store} do
    assert :ok = RegistryStore.add_action(store, email_action())
    cards = RegistryStore.tool_cards(store)

    assert length(cards) == 1
    {id, card} = hd(cards)
    assert id == "Dynamic.Email.send/3"
    assert String.contains?(card, "send")
    assert String.contains?(card, "email")
  end

  test "build_tool_card produces readable card" do
    action = %{
      "name" => "send",
      "module" => "Dynamic.Email",
      "doc" => "Send an outbound email message",
      "args" => [
        %{"name" => "to", "type" => "String.t()", "required" => true, "aliases" => []},
        %{"name" => "subject", "type" => "String.t()", "required" => true, "aliases" => []}
      ],
      "examples" => ["SEND OUTBOUND EMAIL WITH: TO=test@example.com"]
    }

    card = RegistryStore.build_tool_card(action)
    assert String.contains?(card, "Dynamic.Email.send")
    assert String.contains?(card, "Send an outbound email")
    assert String.contains?(card, "to, subject")
  end

  test "normalize_action builds ID from module/name/arity", %{store: store} do
    action = %{
      "module" => "Dynamic.Sms",
      "name" => "send",
      "arity" => 2,
      "doc" => "Send SMS",
      "args" => []
    }

    assert :ok = RegistryStore.add_action(store, action)
    assert RegistryStore.get_action(store, "Dynamic.Sms.send/2") != nil
  end

  test "embedding matrix returns nil when empty", %{store: store} do
    assert RegistryStore.embedding_matrix(store) == nil
  end

  test "put and get embedding", %{store: store} do
    assert :ok = RegistryStore.add_action(store, email_action())

    vec = Nx.tensor([1.0, 2.0, 3.0])
    assert :ok = RegistryStore.put_embedding(store, "Dynamic.Email.send/3", vec)

    {matrix, ids} = RegistryStore.embedding_matrix(store)
    assert ids == ["Dynamic.Email.send/3"]
    assert Nx.shape(matrix) == {1, 3}
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
        %{"name" => "to", "type" => "String.t()", "required" => true, "aliases" => ["recipient", "email"]},
        %{"name" => "subject", "type" => "String.t()", "required" => true, "aliases" => ["title"]},
        %{"name" => "body", "type" => "String.t()", "required" => true, "aliases" => ["message", "text"]}
      ],
      "examples" => ["SEND OUTBOUND EMAIL WITH: TO=user@example.com SUBJECT=\"Status\" BODY=\"Report\""]
    }
  end
end
