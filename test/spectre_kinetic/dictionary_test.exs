defmodule SpectreKinetic.DictionaryTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.TestRegistryHelper

  test "dictionary can be scoped to specific actions" do
    dictionary =
      SpectreKinetic.dictionary!(
        registry_json: TestRegistryHelper.registry_json(),
        actions: ["Linux.Apt.install/1", "Linux.Dnf.install/1"],
        top_n: 20,
        example_limit: 5
      )

    assert dictionary.action_ids == ["Linux.Apt.install/1", "Linux.Dnf.install/1"]
    assert "package" in dictionary.slots
    assert Enum.any?(dictionary.examples, &String.contains?(&1, "APT"))
    refute Enum.any?(dictionary.action_ids, &(&1 == "Elchemista.Blog.create_post/2"))
  end

  test "dictionary_text renders compact prompt text" do
    text =
      SpectreKinetic.dictionary_text!(
        registry_json: TestRegistryHelper.registry_json(),
        actions: ["Linux.Apt.install/1"],
        top_n: 10,
        example_limit: 2
      )

    assert is_binary(text)
    assert text =~ "PACKAGE"
    assert text =~ "package"
  end

  test "non-bang dictionary APIs expose the complete unscoped registry deterministically" do
    path = TestRegistryHelper.registry_json()

    assert {:ok, dictionary} =
             SpectreKinetic.dictionary(
               registry_json: path,
               top_n: 1_000,
               example_limit: 1_000
             )

    assert dictionary.action_ids ==
             TestRegistryHelper.base_actions()
             |> Enum.map(& &1["id"])
             |> Enum.sort()

    assert "INSTALL" in dictionary.keywords
    assert length(dictionary.keywords) == length(Enum.uniq(dictionary.keywords))
    assert dictionary.slots == Enum.sort(dictionary.slots)
    assert length(dictionary.examples) == 7

    assert {:ok, text} =
             SpectreKinetic.dictionary_text(
               registry_json: path,
               actions: [],
               top_n: 0,
               example_limit: 0
             )

    assert text == ""
  end

  test "dictionary boundaries reject malformed scopes and unbounded counts" do
    path = TestRegistryHelper.registry_json()

    for invalid_scope <- ["Linux.Apt.install/1", ["ok", :not_an_id], List.duplicate("id", 1_001)] do
      assert {:error, {:invalid_option, :actions}} =
               SpectreKinetic.Dictionary.build(
                 registry_json: path,
                 actions: invalid_scope
               )
    end

    for {key, value} <- [
          {:top_n, -1},
          {:top_n, 1_001},
          {:top_n, 1.5},
          {:example_limit, -1},
          {:example_limit, 1_001}
        ] do
      assert {:error, {:invalid_option, ^key}} =
               SpectreKinetic.Dictionary.build([registry_json: path] ++ [{key, value}])
    end
  end

  test "dictionary failures stay explicit in tuple and raising APIs" do
    missing = Path.join(System.tmp_dir!(), "missing-registry-#{System.unique_integer()}.json")

    assert {:error, _reason} = SpectreKinetic.Dictionary.build(registry_json: missing)
    assert {:error, _reason} = SpectreKinetic.Dictionary.text(registry_json: missing)

    assert_raise ArgumentError, ~r/failed to build dictionary/, fn ->
      SpectreKinetic.Dictionary.build!(registry_json: missing)
    end

    assert_raise ArgumentError, ~r/failed to build dictionary/, fn ->
      SpectreKinetic.Dictionary.text!(registry_json: missing)
    end
  end
end
