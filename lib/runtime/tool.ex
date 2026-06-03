defmodule SpectreKinetic.Tool do
  @moduledoc """
  Compatibility entry point for declaring Spectre Kinetic tools.

  `use SpectreKinetic.Tool` currently delegates to `use SpectreKinetic`. It is
  kept as a small semantic alias for applications that prefer naming modules by
  the role they play in the registry.
  """

  defmacro __using__(_opts) do
    quote do
      use SpectreKinetic
    end
  end
end
