defmodule SpectreKinetic.ClosedLanguageValidationTest do
  use ExUnit.Case, async: false

  alias SpectreKinetic.Action
  alias SpectreKinetic.Classifiers.PlanConfidence
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.Classifiers.SlotConfidence
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.Planner.SlotType
  alias SpectreKinetic.RuntimeConfig

  test "slot coercion accepts only explicitly declared closed schema types" do
    accepted = [
      {"value", "String.t()", "value"},
      {"value", "binary", "value"},
      {"42", "integer()", 42},
      {0, "non_neg_integer()", 0},
      {"7", "pos_integer", 7},
      {2, "float()", 2.0},
      {"2.5", "number()", 2.5},
      {"YES", "boolean()", true},
      {"off", "boolean", false},
      {"2026-07-29", "Date.t()", "2026-07-29"},
      {~D[2026-07-29], "Date", ~D[2026-07-29]},
      {"2026-07-29T12:00:00Z", "DateTime.t()", "2026-07-29T12:00:00Z"},
      {~U[2026-07-29 12:00:00Z], "DateTime", ~U[2026-07-29 12:00:00Z]},
      {"https://example.com/path", "URI.t()", "https://example.com/path"},
      {URI.parse("https://example.com"), "URI", URI.parse("https://example.com")},
      {%{"safe" => true}, "map()", %{"safe" => true}},
      {[1, 2], "list()", [1, 2]},
      {["1", "2"], "[integer()]", [1, 2]},
      {["1", "2"], "list(integer())", [1, 2]},
      {:ready, "atom()", :ready},
      {:ready, ":ready", :ready},
      {"ready", ":ready", "ready"},
      {nil, "String.t() | nil", nil},
      {"value", "[integer()] | String.t()", "value"},
      {%{anything: self()}, "term()", %{anything: self()}},
      {true, "true", true},
      {"false", "false", false}
    ]

    Enum.each(accepted, fn {value, type, expected} ->
      assert SlotType.coerce(value, type) == {:ok, expected}
    end)

    rejected = [
      {-1, "non_neg_integer()"},
      {0, "pos_integer()"},
      {"1x", "integer()"},
      {"1.2x", "float()"},
      {"maybe", "boolean()"},
      {"2026-02-31", "Date.t()"},
      {"not-a-datetime", "DateTime.t()"},
      {"/relative", "URI.t()"},
      {~D[2026-07-29], "map()"},
      {%{}, "list()"},
      {["1", "bad"], "[integer()]"},
      {"not-a-list", "list(integer())"},
      {"ready", "atom()"},
      {:other, ":ready"},
      {false, "true"},
      {true, "false"},
      {1, ""},
      {1, "[integer()"},
      {1, "list(integer()"},
      {1, "MyApp.Account.t()"}
    ]

    Enum.each(rejected, fn {value, type} ->
      assert {:error, _reason} = SlotType.coerce(value, type)
    end)

    assert SlotType.coerce("value", :not_a_type) ==
             {:error, {:unsupported_type, ":not_a_type"}}

    assert SlotType.coerce("value", "String.t() | MyApp.Account.t()") ==
             {:ok, "value"}

    assert SlotType.coerce(42, "String.t() | MyApp.Account.t()") ==
             {:error, {:unsupported_type, "MyApp.Account.t()"}}
  end

  test "Action serializes planner diagnostics without leaking unsafe runtime terms" do
    suggestions = %{
      "status" => "NO_TOOL",
      "suggestions" => [
        %{"id" => "Mail.send/1", "score" => 0.7, "al_command" => "SEND MAIL"}
      ]
    }

    assert {:ok, %Action{alternatives: [suggestion]}} =
             Action.from_planner_reply("UNKNOWN", {:ok, suggestions})

    assert suggestion == %{
             kind: :suggestion,
             id: "Mail.send/1",
             score: 0.7,
             al: "SEND MAIL"
           }

    assert Action.from_planner_reply("UNKNOWN", {:error, :planner_down}) ==
             {:error, :planner_down}

    candidates =
      Action.from_plan(
        "SEND MAIL",
        %{
          "status" => "ok",
          "candidates" => [
            %{
              "id" => "Mail.send/1",
              "score" => 0.9,
              "tool_score" => 0.8,
              "mapping_score" => 0.7,
              "combined_score" => 0.75
            }
          ]
        },
        3
      )

    assert candidates.index == 3

    assert [candidate] = candidates.alternatives
    assert candidate.kind == :candidate
    assert candidate.combined_score == 0.75

    assert %Action{status: :error, error: {:invalid_al, :verb}, index: 4} =
             Action.error("???", {:invalid_al, :verb}, 4)

    invalid_utf8 = <<255>>
    deep = Enum.reduce(1..40, :leaf, fn index, acc -> %{index => acc} end)

    diagnostic =
      %Action{
        status: :error,
        args: %{
          invalid_utf8 => invalid_utf8,
          :boolean => true,
          :integer => 1,
          :atom => :safe,
          :float => 1.25,
          nil => nil,
          42 => {:bad_input, [~D[2026-07-29], [1, 2 | :tail], fn -> :opaque end]},
          :plain_tuple => {1, 2},
          :deep => deep
        }
      }

    json_map = Action.json_map(diagnostic)
    assert json_map.args["base64:/w=="] == "base64:/w=="
    assert json_map.args["42"].code == :bad_input
    assert json_map.args["42"].details |> hd() |> hd() |> Map.fetch!(:type) == "Elixir.Date"

    assert Enum.any?(
             json_map.args["42"].details |> hd() |> Enum.at(1),
             &match?(%{improper_tail: :tail}, &1)
           )

    assert json_map.args.plain_tuple == [1, 2]
    assert inspect(json_map.args["42"]) =~ "#Function"
    assert inspect(json_map.args.deep) =~ "<max-depth>"

    assert {:ok, encoded} = Jason.encode(diagnostic)
    assert Jason.decode!(encoded)["status"] == "error"
  end

  test "PlanContext preserves classifier ownership and stable foreign status handling" do
    result = %{
      "status" => "MISSING_ARGS",
      "selected_tool" => "Example.run/2",
      "args" => %{"one" => 1},
      "missing" => ["two"],
      "selected_action" => %{"id" => "Example.run/2"},
      "suggestions" => [
        %{"id" => "Example.run/2", "score" => 0.8},
        %{"id" => "Example.other/0", "tool_score" => 0.3}
      ]
    }

    context =
      %PlanContext{
        runtime: nil,
        input: "not valid al",
        mode: :plan,
        planner_result: result,
        status: :missing_args,
        metadata: %{},
        classifier_results: %{},
        warnings: nil,
        halted?: nil
      }

    assert PlanContext.normalized_al(context) == "not valid al"
    assert PlanContext.selected_action(context) == %{"id" => "Example.run/2"}
    assert PlanContext.ranked_tools(context) == result["suggestions"]
    assert PlanContext.scores(context).margin == 0.5

    context =
      context
      |> PlanContext.add_warning("  explainable warning  ")
      |> PlanContext.add_warning(" ")
      |> PlanContext.add_warning(:ignored)
      |> PlanContext.put_classifier_result(:policy, %{decision: :clarify})

    assert context.warnings == ["explainable warning"]
    assert context.classifier_results.policy.decision == :clarify

    public = PlanContext.to_planner_result(%{context | status: :no_tool, halted?: true})
    assert public["status"] == "NO_TOOL"
    assert public["halted?"]

    for {status, expected} <- [
          {"ok", :ok},
          {"AMBIGUOUS_MAPPING", :ambiguous_mapping},
          {"unexpected_foreign_status", :error},
          {:rejected, :rejected},
          {:foreign, :error}
        ] do
      rebuilt =
        PlanContext.from_planner_result(
          %SpectreKinetic.Planner.Runtime{},
          "RUN TASK",
          :plan,
          %{"status" => status}
        )

      assert rebuilt.status == expected
    end

    empty = %{context | planner_result: %{}}
    assert PlanContext.ranked_tools(empty) == []
    assert PlanContext.scores(empty).margin == nil
  end

  test "heuristic slot confidence distinguishes required, optional, alias, and inferred mappings" do
    assert {:ok, unavailable} =
             SlotConfidence.call(context(%{"status" => "ok"}), %{
               mode: :heuristic,
               opts: []
             })

    assert unavailable.classifier_results.slot_confidence.decision == :unavailable

    action = %{
      "id" => "Example.run/4",
      "args" => [
        %{"name" => "exact", "type" => "String.t()", "required" => true},
        %{
          "name" => "renamed",
          "type" => "String.t()",
          "required" => true,
          "aliases" => ["ALIAS"]
        },
        %{"name" => "inferred", "type" => "integer()", "required" => false},
        %{"name" => "optional", "type" => "integer()", "required" => false}
      ]
    }

    planner_result = %{
      "status" => "ok",
      "selected_tool" => "Example.run/4",
      "selected_action" => action,
      "args" => %{
        "exact" => "value",
        "renamed" => "alias-value",
        "inferred" => "2",
        "optional" => "wrong-shape"
      },
      "missing" => []
    }

    input = ~s(RUN TASK EXACT="value" ALIAS="alias-value")
    context = context(planner_result, input)

    assert SlotConfidence.heuristic_slot_confidence(context, Enum.at(action["args"], 0)) ==
             {0.98, "exact"}

    assert SlotConfidence.heuristic_slot_confidence(context, Enum.at(action["args"], 1)) ==
             {0.93, "alias"}

    assert SlotConfidence.heuristic_slot_confidence(context, Enum.at(action["args"], 2)) ==
             {0.82, nil}

    assert SlotConfidence.heuristic_slot_confidence(context, Enum.at(action["args"], 3)) ==
             {0.72, nil}

    assert {:ok, optional_warning} =
             SlotConfidence.call(context, %{
               mode: :heuristic,
               opts: [min_slot_confidence: 0.8]
             })

    assert optional_warning.status == :ok
    assert optional_warning.classifier_results.slot_confidence.decision == :accept

    assert optional_warning.warnings == [
             "one or more optional mapped slots have low confidence"
           ]

    missing_result =
      planner_result
      |> put_in(["missing"], ["renamed"])
      |> update_in(["args"], &Map.delete(&1, "renamed"))

    assert {:ok, required_warning} =
             SlotConfidence.call(context(missing_result, input), %{
               mode: :heuristic,
               opts: [
                 min_slot_confidence: 0.7,
                 low_confidence_status: :needs_clarification
               ]
             })

    assert required_warning.status == :needs_clarification
    assert required_warning.classifier_results.slot_confidence.required_min_confidence == 0.0
    assert required_warning.warnings == ["one or more required mapped slots have low confidence"]
  end

  test "confidence and risk classifiers enrich decisions but never execute them" do
    low =
      context(%{
        "status" => "ok",
        "selected_tool" => "Example.read/0",
        "confidence" => 0.2,
        "missing" => []
      })

    assert {:ok, clarified} =
             PlanConfidence.call(low,
               accept_threshold: 0.8,
               clarify_threshold: 0.5
             )

    assert clarified.status == :needs_clarification
    assert clarified.classifier_results.plan_confidence.decision == :needs_clarification

    medium = put_in(low.planner_result["confidence"], 0.4)
    assert {:ok, confirmed} = PlanConfidence.call(medium, %{mode: :heuristic, opts: []})
    assert confirmed.status == :needs_confirmation

    high =
      context(%{
        "status" => "ok",
        "selected_tool" => "Example.read/0",
        "combined_score" => 2.0,
        "missing" => []
      })

    assert {:ok, accepted} = PlanConfidence.call(high, %{mode: :heuristic, opts: []})
    assert accepted.status == :ok
    assert accepted.classifier_results.plan_confidence.confidence == 1.0

    terminal = %{low | status: :no_tool}
    assert {:ok, unchanged} = PlanConfidence.call(terminal, [])
    assert unchanged.status == :no_tool

    assert {:ok, overridden} =
             PlanConfidence.call(terminal,
               override_terminal_statuses: true,
               clarify_threshold: 0.5
             )

    assert overridden.status == :needs_clarification

    safe = context(%{"status" => "ok"})
    assert {:ok, safe} = SafetyRisk.call(safe, [])
    assert safe.classifier_results.safety_risk.risk == :safe

    destructive =
      context(
        %{
          "status" => "ok",
          "selected_tool" => "System.delete/1",
          "selected_action" => %{"doc" => "Delete and purge records"}
        },
        "DELETE RECORD"
      )

    assert {:halt, risky} =
             SafetyRisk.call(destructive,
               halt_on: [:destructive],
               require_confirmation_for: [:destructive]
             )

    assert risky.status == :needs_confirmation
    assert risky.classifier_results.safety_risk.risk == :destructive
    assert "delete" in risky.classifier_results.safety_risk.matched_terms
  end

  test "runtime configuration applies bounded precedence and rejects hostile payload shapes" do
    keys = [
      :top_k,
      :tool_threshold,
      :mapping_threshold,
      :tool_selection_fallback,
      :fallback_top_k,
      :fallback_margin,
      :reranker_threshold,
      :registry_json
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:spectre_kinetic, &1)})

    env_names = [
      "SPECTRE_KINETIC_TOP_K",
      "SPECTRE_KINETIC_TOOL_THRESHOLD",
      "SPECTRE_KINETIC_MAPPING_THRESHOLD",
      "SPECTRE_KINETIC_TOOL_SELECTION_FALLBACK",
      "SPECTRE_KINETIC_FALLBACK_TOP_K",
      "SPECTRE_KINETIC_FALLBACK_MARGIN",
      "SPECTRE_KINETIC_RERANKER_THRESHOLD",
      "KINETIC_TEST_PATH"
    ]

    previous_env = Map.new(env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:spectre_kinetic, key)
        {key, value} -> Application.put_env(:spectre_kinetic, key, value)
      end)

      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Application.put_env(:spectre_kinetic, :top_k, "invalid")
    Application.put_env(:spectre_kinetic, :tool_threshold, 1)
    Application.put_env(:spectre_kinetic, :mapping_threshold, "invalid")
    Application.put_env(:spectre_kinetic, :tool_selection_fallback, :invalid)
    System.put_env("SPECTRE_KINETIC_TOP_K", "7")
    System.put_env("SPECTRE_KINETIC_MAPPING_THRESHOLD", "0.25")
    System.put_env("SPECTRE_KINETIC_TOOL_SELECTION_FALLBACK", "RERANKER")
    System.put_env("SPECTRE_KINETIC_FALLBACK_TOP_K", "invalid")
    System.put_env("SPECTRE_KINETIC_FALLBACK_MARGIN", "0.4x")

    defaults = RuntimeConfig.default_plan_options()
    assert defaults[:top_k] == 7
    assert defaults[:tool_threshold] == 1.0
    assert defaults[:mapping_threshold] == 0.25
    assert defaults[:tool_selection_fallback] == :reranker
    assert defaults[:fallback_top_k] == 3
    assert defaults[:fallback_margin] == 0.12

    assert RuntimeConfig.built_in_plan_defaults()[:top_k] == 5

    System.put_env("KINETIC_TEST_PATH", "relative/path")

    assert RuntimeConfig.resolve_optional_path([], :missing, :missing, "KINETIC_TEST_PATH") ==
             Path.expand("relative/path")

    assert RuntimeConfig.resolve_optional_path(
             [configured: 42],
             :configured,
             :configured,
             "UNUSED"
           ) == nil

    assert RuntimeConfig.resolve_required_path([], :artifact, :artifact, "KINETIC_MISSING") ==
             {:error, {:missing_path, :artifact, "KINETIC_MISSING"}}

    assert RuntimeConfig.missing_path_message({:missing_path, :artifact, "KINETIC_PATH"}) =~
             "export KINETIC_PATH"

    assert RuntimeConfig.resolve_runtime_paths(registry_json: 42) ==
             {:error,
              {:invalid_options, [%{field: :registry_json, reason: :must_be_non_blank_binary}]}}

    assert RuntimeConfig.decode_request_json(Jason.encode!(%{"al" => "RUN TASK"})) ==
             {:ok, %{"al" => "RUN TASK"}}

    assert {:error, {:json_decode, %Jason.DecodeError{}}} =
             RuntimeConfig.decode_request_json("{")

    assert RuntimeConfig.decode_request_json(:invalid) ==
             {:error, {:invalid_request, [%{field: :json, reason: :must_be_binary}]}}

    assert RuntimeConfig.decode_request_json(String.duplicate(" ", 1_024 * 1_024 + 1)) ==
             {:error, {:invalid_request, [%{field: :json, reason: :exceeds_size_limit}]}}

    assert RuntimeConfig.stringify_map(:invalid) == %{}

    assert RuntimeConfig.stringify_map(%{
             42 => URI.parse("https://example.com"),
             atom: :value,
             nested: %{enabled: true},
             list: [nil, :item, 1, 1.5]
           }) == %{
             "atom" => "value",
             "nested" => %{"enabled" => true},
             "list" => [nil, "item", 1, 1.5],
             "42" => "https://example.com"
           }

    assert RuntimeConfig.normalize_request(:invalid) == %{
             "al" => "",
             "slots" => %{},
             "top_k" => 5
           }

    assert RuntimeConfig.validate_request(:invalid) ==
             {:error, {:invalid_request, [%{field: :request, reason: :must_be_map}]}}

    assert RuntimeConfig.validate_plan_input(<<255>>, []) ==
             {:error, {:invalid_request, [%{field: :al, reason: :must_be_utf8_binary}]}}

    assert RuntimeConfig.validate_options(:invalid) ==
             {:error,
              {:invalid_options, [%{field: :options, reason: :must_be_keyword_or_atom_keyed_map}]}}

    assert RuntimeConfig.validate_options(%{"top_k" => 2}) ==
             {:error,
              {:invalid_options, [%{field: :options, reason: :must_be_keyword_or_atom_keyed_map}]}}

    assert RuntimeConfig.validate_options(slots: %{<<255>> => "value"}) ==
             {:error,
              {:invalid_options, [%{field: :slots, reason: :must_be_json_compatible_map}]}}

    assert RuntimeConfig.validate_options(slots: %{1 => "value"}) ==
             {:error,
              {:invalid_options, [%{field: :slots, reason: :must_be_json_compatible_map}]}}

    assert RuntimeConfig.validate_options(slots: %{"key" => <<255>>}) ==
             {:error,
              {:invalid_options, [%{field: :slots, reason: :must_be_json_compatible_map}]}}

    assert :ok = RuntimeConfig.validate_options(slots: %{empty: [], ratio: 1.5})

    assert RuntimeConfig.validate_options(slots: %{items: Enum.to_list(1..257)}) ==
             {:error, {:invalid_options, [%{field: :slots, reason: :exceeds_complexity_limit}]}}

    strings = Map.new(1..17, &{"key#{&1}", String.duplicate("x", 65_536)})

    assert RuntimeConfig.validate_options(slots: strings) ==
             {:error, {:invalid_options, [%{field: :slots, reason: :exceeds_complexity_limit}]}}
  end

  defp context(planner_result, input \\ "RUN TASK") do
    %PlanContext{
      runtime: nil,
      input: input,
      mode: :plan,
      planner_result: planner_result,
      status: normalize_status(planner_result["status"]),
      metadata: %{},
      classifier_results: %{},
      warnings: [],
      halted?: false
    }
  end

  defp normalize_status("ok"), do: :ok
  defp normalize_status(_other), do: :error
end
