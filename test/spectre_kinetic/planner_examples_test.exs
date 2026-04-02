defmodule SpectreKinetic.PlannerExamplesTest do
  use ExUnit.Case, async: false

  alias SpectreKinetic.Action
  alias SpectreKinetic.ALExamples
  alias SpectreKinetic.TestFixtures

  @moduletag skip: TestFixtures.skip_reason()
  @examples ALExamples.examples()

  setup_all do
    {:ok, pid} =
      start_supervised(
        {SpectreKinetic,
         model_dir: TestFixtures.model_dir(), registry_mcr: TestFixtures.registry_mcr(), name: nil}
      )

    action_defs = ALExamples.action_defs()

    assert length(@examples) == 1_000

    Enum.each(action_defs, fn action ->
      assert :ok = SpectreKinetic.add_action(pid, action)
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        Enum.each(action_defs, fn action ->
          SpectreKinetic.delete_action(pid, action.id)
        end)
      end
    end)

    {:ok, pid: pid}
  end

  test "generator returns exactly 1000 AL examples" do
    assert length(@examples) == 1_000
    assert Enum.all?(@examples, &is_binary(&1.al))
    assert Enum.all?(@examples, &is_binary(&1.tool_id))
    assert Enum.all?(@examples, &(is_map(&1.expected_args) and map_size(&1.expected_args) > 0))
  end

  for {example, index} <- Enum.with_index(@examples, 1) do
    label =
      [
        example.tool_id,
        example.al
        |> String.replace("\"", "'")
        |> String.slice(0, 80)
      ]
      |> Enum.join(" | ")

    @tag planner_example_index: index
    test "planner example #{index}: #{label}", %{pid: pid} do
      example = unquote(Macro.escape(example))

      case SpectreKinetic.plan(pid, example.al, tool_threshold: 0.0, mapping_threshold: 0.0) do
        {:ok, %Action{} = action} ->
          failures = planner_failures(example, action)

          assert failures == [],
                 """
                 planner example failed
                 al: #{example.al}
                 expected tool: #{example.tool_id}
                 failures:
                 #{Enum.join(failures, "\n")}
                 """

        {:error, reason} ->
          flunk("""
          planner example failed
          al: #{example.al}
          expected tool: #{example.tool_id}
          planner error: #{inspect(reason)}
          """)
      end
    end
  end

  defp planner_failures(example, action) do
    []
    |> maybe_add_failure(
      action.status == :ok,
      "expected :ok for #{inspect(example.al)}, got #{inspect(action)}"
    )
    |> maybe_add_failure(
      action.selected_tool == example.tool_id,
      "wrong tool for #{inspect(example.al)} expected #{example.tool_id} got #{inspect(action.selected_tool)}"
    )
    |> maybe_add_failure(
      action.missing == [],
      "unexpected missing args for #{inspect(example.al)}: #{inspect(action.missing)}"
    )
    |> then(fn failures ->
      failures ++
        Enum.flat_map(example.expected_args, fn {key, value} ->
          if action.args[key] == value do
            []
          else
            [
              "wrong arg #{inspect(key)} for #{inspect(example.al)} expected #{inspect(value)} got #{inspect(action.args[key])} full args=#{inspect(action.args)}"
            ]
          end
        end)
    end)
  end

  defp maybe_add_failure(failures, true, _message), do: failures
  defp maybe_add_failure(failures, false, message), do: failures ++ [message]
end
