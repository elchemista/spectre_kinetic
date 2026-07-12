defmodule SpectreKinetic.Action do
  @moduledoc """
  Structured result for one planned AL instruction.

  This struct intentionally stays close to the planner result payload.
  It keeps only the fields that are usually needed to decide whether
  a tool can be executed, retried, or shown back to an LLM.

  `Action` is the public boundary object. Inside the planner we keep rich maps
  because ranking and mapping features are assembled from several sources. At
  the API boundary, those maps are normalized into this struct so callers can
  pattern match on a stable shape:

      {:ok, %SpectreKinetic.Action{status: :ok, args: args}} =
        SpectreKinetic.plan(runtime, "SEND EMAIL WITH: TO=dev@example.com")

      {:ok, %SpectreKinetic.Action{status: :no_tool, alternatives: suggestions}} =
        SpectreKinetic.plan(runtime, "DO SOMETHING UNKNOWN", tool_threshold: 0.99)

  The module does not repair planner output. Alias resolution, type coercion,
  and policy decisions must finish before this boundary so conversion cannot
  make an action more executable than the validated planner result.
  """

  @derive {Jason.Encoder,
           only: [
             :index,
             :al,
             :status,
             :selected_tool,
             :confidence,
             :tool_score,
             :mapping_score,
             :combined_score,
             :args,
             :invalid,
             :missing,
             :notes,
             :classifier_results,
             :warnings,
             :halted?,
             :alternatives,
             :error
           ]}

  defstruct index: nil,
            al: nil,
            status: nil,
            selected_tool: nil,
            confidence: nil,
            tool_score: nil,
            mapping_score: nil,
            combined_score: nil,
            args: %{},
            invalid: [],
            missing: [],
            notes: [],
            classifier_results: %{},
            warnings: [],
            halted?: false,
            alternatives: [],
            error: nil

  @known_statuses %{
    "ok" => :ok,
    "no_tool" => :no_tool,
    "missing_args" => :missing_args,
    "ambiguous_mapping" => :ambiguous_mapping,
    "needs_confirmation" => :needs_confirmation,
    "needs_clarification" => :needs_clarification,
    "rejected" => :rejected,
    "error" => :error
  }

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
            optional(:al) => binary() | nil,
            optional(:tool_score) => float() | integer() | nil,
            optional(:mapping_score) => float() | integer() | nil,
            optional(:combined_score) => float() | integer() | nil
          }

  @typedoc """
  One planned action result.
  """
  @type t :: %__MODULE__{
          index: non_neg_integer() | nil,
          al: binary() | nil,
          status: atom() | nil,
          selected_tool: binary() | nil,
          confidence: float() | nil,
          tool_score: float() | nil,
          mapping_score: float() | nil,
          combined_score: float() | nil,
          args: map(),
          invalid: [map()],
          missing: [binary()],
          notes: [binary()],
          classifier_results: map(),
          warnings: [binary()],
          halted?: boolean(),
          alternatives: [alternative()],
          error: term()
        }

  @doc """
  Builds an action struct from the decoded planner payload.

  The input `plan` is the external map shape produced by the planner. This
  function is intentionally the place where string statuses, JSON-style keys,
  and compatibility repairs are converted into the Elixir struct shape.

  ## Examples

      iex> plan = %{
      ...>   "status" => "ok",
      ...>   "selected_tool" => "Mail.send/1",
      ...>   "args" => %{"to" => "dev@example.com"}
      ...> }
      iex> action = SpectreKinetic.Action.from_plan("SEND EMAIL TO=dev@example.com", plan)
      iex> {action.status, action.selected_tool, action.args["to"]}
      {:ok, "Mail.send/1", "dev@example.com"}

  Unknown string statuses are treated as `:error` instead of being converted
  to atoms. That keeps foreign planner payloads from growing the VM atom table.
  """
  @spec from_plan(binary(), map(), non_neg_integer() | nil) :: t()
  def from_plan(al, plan, index \\ nil) when is_binary(al) and is_map(plan) do
    %__MODULE__{
      index: index,
      al: al,
      status: normalize_status(plan["status"]),
      selected_tool: plan["selected_tool"],
      confidence: plan["confidence"] || plan["combined_score"],
      tool_score: plan["tool_score"],
      mapping_score: plan["mapping_score"],
      combined_score: plan["combined_score"],
      args: plan["args"] || %{},
      invalid: plan["invalid"] || [],
      missing: plan["missing"] || [],
      notes: plan["notes"] || [],
      classifier_results: plan["classifier_results"] || %{},
      warnings: plan["warnings"] || [],
      halted?: Map.get(plan, "halted?", false),
      alternatives: build_alternatives(plan)
    }
  end

  @doc false
  @spec from_planner_reply(binary(), {:ok, map()} | {:error, term()}) ::
          {:ok, t()} | {:error, term()}
  def from_planner_reply(al_text, {:ok, plan}) when is_map(plan) do
    {:ok, from_plan(al_text, plan)}
  end

  def from_planner_reply(_al_text, {:error, reason}), do: {:error, reason}

  @doc """
  Builds an error action for extraction or wrapper failures.

  Use this when planning could not produce a planner payload at all, for
  example when AL extraction fails before tool selection starts.

  ## Example

      iex> action = SpectreKinetic.Action.error("???", :invalid_al_verb, 0)
      iex> {action.status, action.error, action.index}
      {:error, :invalid_al_verb, 0}
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

  # Status text crosses from maps and JSON into the VM. We keep the door narrow;
  # atoms are forever, and forever is a long time to debug.
  defp normalize_status(other) when is_binary(other) do
    Map.get(@known_statuses, String.downcase(other), :error)
  end

  defp normalize_status(other), do: other

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

  defp build_alternatives(%{"candidates" => [_ | _] = candidates}) do
    Enum.map(candidates, fn candidate ->
      %{
        kind: :candidate,
        id: candidate["id"],
        score: candidate["score"],
        tool_score: candidate["tool_score"],
        mapping_score: candidate["mapping_score"],
        combined_score: candidate["combined_score"]
      }
    end)
  end

  defp build_alternatives(_plan), do: []
end
