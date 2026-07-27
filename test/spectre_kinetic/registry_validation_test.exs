defmodule SpectreKinetic.RegistryValidationTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Registry
  alias SpectreKinetic.Planner.Registry.ETS

  test "normalization rejects internally inconsistent action schemas" do
    base = action()

    assert {:error, {:arity_mismatch, 1, 0}} =
             Registry.normalize_action(%{base | "args" => []})

    assert {:error, {:invalid_field, "id", {:mfa_mismatch, "Example.run/1"}}} =
             Registry.normalize_action(%{base | "id" => "Other.run/1"})

    assert {:error, {:invalid_arg, 0, {:invalid_field, "aliases", :must_be_list}}} =
             Registry.normalize_action(%{
               base
               | "args" => [%{"name" => "input", "aliases" => 123}]
             })

    assert {:error, {:ambiguous_arg_name, "INPUT", 0, 0}} =
             Registry.normalize_action(%{
               base
               | "args" => [%{"name" => "input", "aliases" => ["INPUT"]}]
             })
  end

  test "malformed JSON registries do not mutate live actions" do
    {:ok, registry} = ETS.new()
    {:ok, registry} = ETS.add_action(registry, action())

    on_exit(fn -> ETS.close(registry) end)

    malformed_path =
      write_registry([
        %{action() | "args" => [%{"name" => "input", "aliases" => 123}]}
      ])

    assert {:error,
            {:invalid_action, 0, {:invalid_arg, 0, {:invalid_field, "aliases", :must_be_list}}}} =
             ETS.load_json(registry, malformed_path)

    assert ETS.action_count(registry) == 1
    assert ETS.get_action(registry, "Example.run/1")["name"] == "run"
  end

  test "duplicate action IDs are rejected before live tables are replaced" do
    {:ok, registry} = ETS.new()
    {:ok, registry} = ETS.add_action(registry, action())

    on_exit(fn -> ETS.close(registry) end)

    duplicate_path = write_registry([action(), action()])

    assert {:error, {:duplicate_action_id, "Example.run/1"}} =
             ETS.load_json(registry, duplicate_path)

    assert ETS.action_count(registry) == 1
  end

  test "registry JSON reads and schema collections are bounded" do
    {:ok, registry} = ETS.new()
    {:ok, registry} = ETS.add_action(registry, action())
    on_exit(fn -> ETS.close(registry) end)

    oversized_path = write_raw_registry(String.duplicate(" ", 4 * 1_024 * 1_024 + 1))

    assert {:error, {:artifact_too_large, ^oversized_path, _size, 4_194_304}} =
             ETS.load_json(registry, oversized_path)

    too_many_actions =
      Enum.map(1..1_001, fn index ->
        %{
          "id" => "Example.run_#{index}/0",
          "module" => "Example",
          "name" => "run_#{index}",
          "arity" => 0,
          "args" => []
        }
      end)

    assert {:error, {:too_many_actions, 1_001, 1_000}} =
             ETS.load_json(registry, write_registry(too_many_actions))

    assert {:error, {:invalid_field, "args", :too_many_entries}} =
             Registry.normalize_action(%{
               action()
               | "arity" => 129,
                 "id" => "Example.run/129",
                 "args" => Enum.map(1..129, &%{"name" => "arg_#{&1}"})
             })

    assert {:error, {:invalid_field, "doc", :exceeds_size_limit}} =
             action()
             |> Map.put("doc", String.duplicate("x", 65_537))
             |> Registry.normalize_action()

    assert ETS.action_count(registry) == 1
  end

  defp action do
    %{
      "id" => "Example.run/1",
      "module" => "Example",
      "name" => "run",
      "arity" => 1,
      "args" => [%{"name" => "input", "aliases" => ["value"]}],
      "examples" => ["RUN EXAMPLE WITH: INPUT=value"]
    }
  end

  defp write_registry(actions) do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-kinetic-invalid-registry-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(%{"actions" => actions}))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_raw_registry(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-kinetic-raw-registry-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
