defmodule SpectreKinetic.ActionChain do
  @moduledoc """
  Ordered list of actions extracted from a text response or an explicit AL list.

  The chain stays intentionally small. It is just the execution-ordered
  collection of `%SpectreKinetic.Action{}` values returned by `plan_chain/3`.
  """

  alias SpectreKinetic.Action

  @derive {Jason.Encoder, only: [:actions]}

  defstruct [
    # Ordered planned actions, including failed extraction/planning entries.
    actions: []
  ]

  @typedoc """
  Ordered action chain result.
  """
  @type t :: %__MODULE__{
          actions: [Action.t()]
        }

  @doc """
  Builds a new action chain from a map of attributes.

  Currently only `:actions` is stored, but the constructor keeps the call site
  readable and leaves room for future extension without changing callers.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{actions: Map.get(attrs, :actions, [])}
  end

  @doc """
  Returns only successful actions from a chain.
  """
  @spec ok_actions(t()) :: [Action.t()]
  def ok_actions(%__MODULE__{actions: actions}) do
    Enum.filter(actions, &(&1.status == :ok))
  end

  @doc """
  Returns the number of actions in the chain.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{actions: actions}), do: length(actions)
end
