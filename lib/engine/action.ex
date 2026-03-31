defmodule SpectreKinetic.Action do
  @moduledoc """
  Structured result for one planned AL instruction.

  This struct intentionally stays close to the Rust planner output.
  It keeps only the fields that are usually needed to decide whether
  a tool can be executed, retried, or shown back to an LLM.
  """

  @derive {Jason.Encoder,
           only: [
             :index,
             :al,
             :status,
             :selected_tool,
             :confidence,
             :args,
             :missing,
             :notes,
             :alternatives,
             :error
           ]}

  defstruct [
    # Position inside an extracted action chain. `nil` for single-action planning.
    index: nil,
    # The AL string that was actually planned.
    al: nil,
    # Planner outcome such as `:ok`, `:no_tool`, `:missing_args`, or `:error`.
    status: nil,
    # Selected tool id returned by the Rust planner.
    selected_tool: nil,
    # Similarity/confidence score of the selected tool.
    confidence: nil,
    # Final mapped arguments ready to pass to the selected tool.
    args: %{},
    # Required parameters still missing after mapping and defaults.
    missing: [],
    # Planner notes, for example unmatched slots or mapping remarks.
    notes: [],
    # Fallback entries exposed as either candidates or suggestions.
    alternatives: [],
    # Wrapper-level or extraction-level error reason.
    error: nil
  ]

  @typedoc """
  One alternative returned when the planner has either:

  - ranked nearby tools as normal candidates
  - generated suggestion entries when no tool passed the confidence threshold
  """
  @type alternative ::
          %{
            required(:kind) => :candidate | :suggestion,
            required(:id) => binary(),
            required(:score) => float() | integer() | nil,
            optional(:al) => binary() | nil
          }

  @typedoc """
  One planned action result.

  The most important fields in practice are `selected_tool`, `confidence`,
  `args`, `status`, and `alternatives`.
  """
  @type t :: %__MODULE__{
          index: non_neg_integer() | nil,
          al: binary() | nil,
          status: atom() | nil,
          selected_tool: binary() | nil,
          confidence: float() | nil,
          args: map(),
          missing: [binary()],
          notes: [binary()],
          alternatives: [alternative()],
          error: term()
        }

  @doc """
  Builds an action struct from the decoded Rust planner payload.

  This function also performs a small Elixir-side repair step for obvious
  literal values already present in the AL text when the planner reports
  missing args for those same exact slot names.
  """
  @spec from_plan(binary(), map(), non_neg_integer() | nil) :: t()
  def from_plan(al, plan, index \\ nil) when is_binary(al) and is_map(plan) do
    repaired = repair_missing_args(plan, SpectreKinetic.Parser.args(al))

    %__MODULE__{
      index: index,
      al: al,
      status: normalize_status(repaired["status"]),
      selected_tool: repaired["selected_tool"],
      confidence: repaired["confidence"],
      args: repaired["args"] || %{},
      missing: repaired["missing"] || [],
      notes: repaired["notes"] || [],
      alternatives: build_alternatives(repaired)
    }
  end

  @doc """
  Builds an error action for extraction or wrapper failures.

  This is used for cases where the Rust planner was not able to run because
  the extracted AL block was malformed or rejected before planning.
  """
  @spec error(binary() | nil, term(), non_neg_integer() | nil) :: t()
  def error(al, reason, index \\ nil) do
    %__MODULE__{
      index: index,
      al: al,
      status: :error,
      error: reason
    }
  end

  defp normalize_status("ok"), do: :ok
  defp normalize_status("NO_TOOL"), do: :no_tool
  defp normalize_status("MISSING_ARGS"), do: :missing_args
  defp normalize_status("AMBIGUOUS_MAPPING"), do: :ambiguous_mapping

  defp normalize_status(other) when is_binary(other),
    do: other |> String.downcase() |> String.to_atom()

  defp normalize_status(other), do: other

  # Reuse literal values from the AL text only for exact missing arg names.
  # This keeps the Elixir wrapper small while still smoothing over obvious
  # `WITH:` cases that the planner may leave unresolved.
  defp repair_missing_args(plan, parsed_args) do
    missing = plan["missing"] || []
    current_args = plan["args"] || %{}

    recovered =
      parsed_args
      |> Map.new(fn {key, value} -> {String.downcase(key), value} end)
      |> Map.take(missing)

    merge_recovered_args(plan, current_args, missing, recovered)
  end

  defp merge_recovered_args(plan, _current_args, _missing, recovered)
       when map_size(recovered) == 0, do: plan

  defp merge_recovered_args(plan, current_args, missing, recovered) do
    args = Map.merge(current_args, recovered)
    remaining_missing = Enum.reject(missing, &Map.has_key?(args, &1))

    plan
    |> Map.put("args", args)
    |> Map.put("missing", remaining_missing)
    |> Map.put("status", repaired_status(plan["status"], remaining_missing))
  end

  defp repaired_status(_status, []), do: "ok"
  defp repaired_status(status, _remaining_missing), do: status

  # Suggestions appear when no tool passed the confidence threshold.
  defp build_alternatives(%{"suggestions" => [_ | _] = suggestions}) do
    Enum.map(suggestions, fn suggestion ->
      %{
        kind: :suggestion,
        id: suggestion["id"],
        score: suggestion["score"],
        al: suggestion["al_command"]
      }
    end)
  end

  # Candidates appear when the planner did rank tools but none need to be
  # expanded into suggestion commands.
  defp build_alternatives(%{"candidates" => [_ | _] = candidates}) do
    Enum.map(candidates, fn candidate ->
      %{
        kind: :candidate,
        id: candidate["id"],
        score: candidate["score"]
      }
    end)
  end

  defp build_alternatives(_plan), do: []
end
