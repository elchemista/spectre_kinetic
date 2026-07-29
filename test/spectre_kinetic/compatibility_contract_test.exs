defmodule SpectreKinetic.CompatibilityContractTest do
  use ExUnit.Case, async: false

  alias SpectreKinetic.Action
  alias SpectreKinetic.ActionChain
  alias SpectreKinetic.Server
  alias SpectreKinetic.TestRegistryHelper
  alias SpectreKinetic.ToolFixtures.{Emailer, Sms}

  test "legacy server entry point preserves the runtime mutation and planning contract" do
    registry = TestRegistryHelper.registry_json()
    {:ok, server} = Server.start_link(registry_json: registry, name: nil)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert Server.action_count(server) == 4
    assert length(SpectreKinetic.action_definitions(server)) == 4

    assert {:ok, %Action{selected_tool: "Linux.Apt.install/1"}} =
             Server.plan(server, "INSTALL PACKAGE nginx VIA APT", tool_threshold: 0.0)

    request = %{"al" => "LIST DIRECTORY /tmp", "slots" => %{}}

    assert {:ok, %Action{selected_tool: "Linux.Coreutils.ls/1"}} =
             Server.plan_request(server, request)

    assert {:ok, %Action{selected_tool: "Linux.Coreutils.ls/1"}} =
             Server.plan_json(server, Jason.encode!(request))

    dynamic = %{
      "id" => "Example.ping/0",
      "module" => "Example",
      "name" => "ping",
      "arity" => 0,
      "doc" => "Ping the example service",
      "spec" => "ping() :: :ok",
      "args" => [],
      "examples" => ["PING EXAMPLE SERVICE"]
    }

    assert :ok = Server.add_action(server, dynamic)
    assert Server.action_count(server) == 5
    assert {:ok, true} = Server.delete_action(server, "Example.ping/0")
    assert :ok = Server.reload_registry(server, registry)
    assert Server.action_count(server) == 4
  end

  test "compatibility tool macro emits the same executable metadata" do
    module =
      Module.concat([
        __MODULE__,
        String.to_atom("Tool#{System.unique_integer([:positive])}")
      ])

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use SpectreKinetic.Tool

      @al "PING SERVICE"
      def ping(service), do: {:ok, service}
    end
    """)

    assert [%{function: :ping, params: ["service"], al: "PING SERVICE"}] =
             module.__spectre_tools__()

    assert module.ping("api") == {:ok, "api"}
  end

  test "action chains expose only successful actions without losing order" do
    ok = %Action{al: "ONE", index: 0, status: :ok}
    rejected = %Action{al: "TWO", index: 1, status: :error, error: :invalid}
    later = %Action{al: "THREE", index: 2, status: :ok}
    chain = ActionChain.new(%{actions: [ok, rejected, later]})

    assert ActionChain.ok_actions(chain) == [ok, later]
    assert ActionChain.count(chain) == 3
    assert ActionChain.new(%{}).actions == []
  end

  test "tool fixtures are real callable examples, not metadata-only facades" do
    assert Emailer.send("dev@example.com", "hello") ==
             {:ok, "dev@example.com:hello"}

    assert Sms.send("+15551234567", "hello") == :ok
    assert MyApp.Emailer.send("ops@example.com", "pager") == {:ok, "ops@example.com:pager"}
  end
end
