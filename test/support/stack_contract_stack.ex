defmodule SpectreKinetic.StackContractActions do
  @moduledoc false

  use SpectreKinetic

  @al ~s(PING TARGET="stack")
  @doc "Returns a deterministic ping result."
  @spec ping(String.t()) :: {:ok, String.t()}
  def ping(target) do
    if pid = Process.whereis(SpectreKinetic.StackContractProbe) do
      send(pid, {:kinetic_action_executed, target})
    end

    {:ok, "pong #{target}"}
  end
end

defmodule SpectreKinetic.StackContractModel do
  @moduledoc false

  def complete(_prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, :kinetic_model_called)
    {:ok, ~s(Planning complete.\n<al>PING TARGET="stack"</al>)}
  end
end

defmodule SpectreKinetic.StackContractStack do
  @moduledoc false

  use Spectre.Stack, id: :kinetic_contract

  install Spectre.Kinetic,
    mode: :closed_moves,
    actions: SpectreKinetic.StackContractActions,
    modes: [ping: :read] do
    classifier(SpectreKinetic.Classifiers.PlanConfidence, fallback: :heuristic)

    classifier(SpectreKinetic.Classifiers.SafetyRisk,
      fallback: :heuristic,
      threshold: 0.85,
      outcome: :reject
    )
  end
end
