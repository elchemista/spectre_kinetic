defmodule Spectre.Kinetic.Extension do
  @moduledoc false

  @spec id() :: :kinetic
  def id, do: :kinetic

  @spec api_version() :: 1
  def api_version, do: 1

  @spec compile(module(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def compile(_owner, opts) do
    case Keyword.get(opts, :stack_config) do
      %{options: _, classifiers: _} = config ->
        {:ok, stack_options(config)}

      invalid ->
        {:error, {:invalid_kinetic_stack_config, invalid}}
    end
  end

  @spec stack_options(Spectre.Kinetic.stack_config()) :: keyword()
  def stack_options(%{options: options, classifiers: classifiers}) do
    classifier_specs =
      Enum.map(classifiers, fn
        %{module: module, options: []} -> module
        %{module: module, options: classifier_opts} -> {module, classifier_opts}
      end)

    Keyword.put(options, :classifiers, classifier_specs)
  end

  @spec agent_config(keyword()) :: keyword()
  def agent_config(config) when is_list(config), do: [kinetic: config]

  @spec action_providers(keyword()) :: [tuple()]
  def action_providers(opts) do
    case Keyword.get(opts, :actions) do
      nil ->
        []

      module when is_atom(module) and not is_nil(module) ->
        provider_opts =
          opts
          |> Keyword.take([:mode, :modes])
          |> provider_modes()
          |> Keyword.put(:module, module)

        [
          {
            Keyword.get(opts, :provider, :kinetic),
            Spectre.Kinetic.Actions,
            provider_opts
          }
        ]

      invalid ->
        raise ArgumentError,
              "Spectre.Kinetic :actions must be a module, got: #{inspect(invalid)}"
    end
  end

  # The interpreter's closed-moves configuration is not an Action's effect
  # mode. Only per-action modes or an explicit action default reach the catalog.
  defp provider_modes(opts) do
    if Keyword.get(opts, :mode) == :closed_moves,
      do: Keyword.delete(opts, :mode),
      else: opts
  end

  @spec planner_options(keyword()) :: keyword()
  def planner_options(opts), do: Keyword.drop(opts, [:actions, :provider, :mode, :modes])
end
