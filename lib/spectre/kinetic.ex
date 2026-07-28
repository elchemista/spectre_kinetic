defmodule Spectre.Kinetic do
  @moduledoc """
  Stack package and legacy Agent integration for `SpectreKinetic`.

  Install Kinetic in a `Spectre.Stack` to declare the classifier pipeline used
  to interpret constrained decisions:

      install Spectre.Kinetic, mode: :closed_moves do
        classifier MyApp.IntentClassifier
        classifier MyApp.SafetyClassifier, threshold: 0.85
      end

  The Stack configuration is immutable data. It does not start a planner,
  register action providers, or execute the selected decision. Kinetic owns
  interpretation; the Spectre core owns authorization and execution.

  The legacy Agent extension remains available:

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

  alias Spectre.Stack.DSL

  use Spectre.Stack.Installable,
    id: :kinetic,
    version: "0.1.2",
    contract: 1,
    spectre: "~> 0.1.2",
    provides: [{:service, :kinetic}],
    dsl: __MODULE__,
    metadata: %{role: :decision_interpreter}

  @type classifier_config :: %{
          required(:module) => module(),
          required(:options) => keyword()
        }

  @type stack_config :: %{
          required(:options) => keyword(),
          required(:classifiers) => [classifier_config()]
        }

  @doc false
  @impl Spectre.Stack.Installable
  @spec compile(keyword(), Macro.t() | nil, Macro.Env.t()) :: {:ok, stack_config()}
  def compile(opts, block, caller) do
    classifiers =
      block
      |> DSL.compile!(caller, classifier: [1, 2])
      |> Enum.map(&classifier_config!/1)

    {:ok, %{options: opts, classifiers: classifiers}}
  end

  defmacro __using__(opts) do
    quote do
      Spectre.Extension.register!(
        __MODULE__,
        Spectre.Kinetic.Extension,
        unquote(opts)
      )
    end
  end

  @spec classifier_config!({:classifier, [term()]}) :: classifier_config()
  defp classifier_config!({:classifier, [module]}), do: classifier_config!(module, [])

  defp classifier_config!({:classifier, [module, options]}),
    do: classifier_config!(module, options)

  @spec classifier_config!(term(), term()) :: classifier_config()
  defp classifier_config!(module, options)
       when is_atom(module) and not is_nil(module) and is_list(options) do
    if Keyword.keyword?(options) do
      %{module: module, options: options}
    else
      raise ArgumentError,
            "Spectre.Kinetic classifier options must be a keyword list, got: #{inspect(options)}"
    end
  end

  defp classifier_config!(module, options) do
    raise ArgumentError,
          "Spectre.Kinetic classifier must be a module with keyword options, got: " <>
            "#{inspect(module)}, #{inspect(options)}"
  end
end
