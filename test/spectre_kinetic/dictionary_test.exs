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
end
