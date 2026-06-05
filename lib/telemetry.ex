defmodule SpectreKinetic.Telemetry do
  @moduledoc false

  @app :spectre_kinetic

  @type metadata :: map() | keyword()

  @spec execute([atom()], map(), metadata()) :: :ok
  def execute(event, measurements, metadata \\ %{})
      when is_list(event) and is_map(measurements) do
    if enabled?() do
      :telemetry.execute(event, measurements, Map.new(metadata))
    else
      :ok
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(@app, :telemetry_enabled, true)
  end
end
