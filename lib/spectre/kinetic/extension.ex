defmodule Spectre.Kinetic.Extension do
  @moduledoc false

  @spec id() :: :kinetic
  def id, do: :kinetic

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

  @spec action_planner(keyword()) :: {module(), keyword()}
  def action_planner(opts) do
    planner_opts = Keyword.drop(opts, [:actions, :provider, :mode, :modes])
    {Spectre.Kinetic.Planner, planner_opts}
  end
end
