defmodule SpectreKinetic.ParserTest do
  use ExUnit.Case, async: true

  test "parse_al extracts explicit and loose inline args" do
    assert %{args: %{"TO" => "yuriy.zhar@gmail.com"}} =
             SpectreKinetic.parse_al("SEND ME EMAIL TO=yuriy.zhar@gmail.com")

    assert %{args: %{"TO" => "yuriy.zhar@gmail.com"}} =
             SpectreKinetic.parse_al("SEND ME EMAIL TO: yuriy.zhar@gmail.com")

    assert %{args: %{"TO" => "yuriy.zhar@gmail.com"}} =
             SpectreKinetic.parse_al("SEND ME EMAIL to yuriy.zhar@gmail.com")
  end
end
