defmodule Spectre.Kinetic do
  @moduledoc """
  On-demand Spectre Agent integration for `SpectreKinetic`.

  Mount this after the core Agent DSL:

      use Spectre.Agent
      use Spectre.Kinetic,
        actions: MyApp.Actions,
        runtime: MyApp.KineticRuntime

  `:actions` mounts the built-in `Spectre.Kinetic.Actions` provider, so the
  application does not need to implement an adapter. Omit it when other
  extensions, such as MCP or Lens, already contribute the providers that
  Kinetic should plan.

  Spectre keeps ownership of policy, persistence, and execution lifecycle.
  """

  defmacro __using__(opts) do
    quote do
      Spectre.Extension.register!(
        __MODULE__,
        Spectre.Kinetic.Extension,
        unquote(opts)
      )
    end
  end
end
