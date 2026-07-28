defmodule Spectre.Kinetic.Extension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl true
  @spec id() :: :kinetic
  def id, do: :kinetic

  @impl true
  def api_version, do: 1

  @impl true
  def compile(_owner, opts) do
    case Keyword.fetch(opts, :stack_config) do
      {:ok, %{options: options, classifiers: classifiers}} ->
        classifier_specs =
          Enum.map(classifiers, fn
            %{module: module, options: []} -> module
            %{module: module, options: classifier_opts} -> {module, classifier_opts}
          end)

        {:ok, Keyword.put(options, :classifiers, classifier_specs)}

      :error ->
        {:ok, opts}

      {:ok, invalid} ->
        {:error, {:invalid_kinetic_stack_config, invalid}}
    end
  end

  @impl true
  def agent_config(config) when is_list(config), do: [kinetic: config]

  @impl true
  @spec action_providers(keyword()) :: [tuple()]
  def action_providers(opts) do
    case Keyword.get(opts, :actions) do
      nil ->
        []

      module when is_atom(module) and not is_nil(module) ->
        provider_opts =
          opts
          |> Keyword.take([:mode, :modes])
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

  @impl true
  @spec action_planner(keyword()) :: {module(), keyword()}
  def action_planner(opts) do
    planner_opts = Keyword.drop(opts, [:actions, :provider, :mode, :modes])
    {Spectre.Kinetic.Planner, planner_opts}
  end
end
