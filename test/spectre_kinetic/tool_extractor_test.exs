defmodule SpectreKinetic.ToolExtractorTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ExtractKinetic
  alias SpectreKinetic.Tool.Extractor
  alias SpectreKinetic.ToolFixtures.Emailer
  alias SpectreKinetic.ToolFixtures.Sms

  test "extract_module/1 builds canonical action metadata from @al and AL doc lines" do
    assert {:ok, [action]} = Extractor.extract_module(Emailer)

    assert action["id"] == "Elixir.SpectreKinetic.ToolFixtures.Emailer.send/2"
    assert action["module"] == "Elixir.SpectreKinetic.ToolFixtures.Emailer"
    assert action["name"] == "send"
    assert action["arity"] == 2
    assert action["doc"] == "Send an email to a recipient."
    assert action["spec"] =~ "send(email :: String.t(), text :: String.t())"

    assert action["examples"] == [
             "SEND EMAIL TO=email@gmail.com BODY=text",
             ~s(SEND EMAIL TO="dev@example.com" BODY="hello"),
             ~s(SEND MAIL TO="ops@example.com" BODY="pager")
           ]

    assert action["args"] == [
             %{
               "name" => "email",
               "type" => "String.t()",
               "required" => true,
               "aliases" => ["TO"]
             },
             %{
               "name" => "text",
               "type" => "String.t()",
               "required" => true,
               "aliases" => ["BODY"]
             }
           ]
  end

  test "exact slot-name matches do not need inferred aliases" do
    assert {:ok, [action]} = Extractor.extract_module(Sms)

    assert action["doc"] == "Send an SMS message."

    assert action["args"] == [
             %{
               "name" => "to",
               "type" => "String.t()",
               "required" => true,
               "aliases" => []
             },
             %{
               "name" => "body",
               "type" => "String.t()",
               "required" => true,
               "aliases" => []
             }
           ]
  end

  test "mix extract_kinetic writes registry json from compiled tool modules" do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre_extract_kinetic_#{System.unique_integer([:positive])}.json"
      )

    Mix.Task.reenable("extract_kinetic")
    ExtractKinetic.run(["--app", "spectre_kinetic", "--out", path])

    assert {:ok, payload} = File.read(path)
    decoded = Jason.decode!(payload)
    ids = Enum.map(decoded["actions"], & &1["id"])

    assert "Elixir.SpectreKinetic.ToolFixtures.Emailer.send/2" in ids
    assert "Elixir.SpectreKinetic.ToolFixtures.Sms.send/2" in ids
  end
end
