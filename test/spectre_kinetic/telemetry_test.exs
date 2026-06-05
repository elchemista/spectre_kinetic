defmodule SpectreKinetic.TelemetryTest do
  use ExUnit.Case, async: false

  alias SpectreKinetic.Telemetry
  alias SpectreKinetic.TelemetryHelper

  @event [:spectre_kinetic, :test, :event]

  setup do
    previous = Application.get_env(:spectre_kinetic, :telemetry_enabled, true)

    on_exit(fn ->
      Application.put_env(:spectre_kinetic, :telemetry_enabled, previous)
    end)
  end

  test "execute/3 emits telemetry when enabled" do
    Application.put_env(:spectre_kinetic, :telemetry_enabled, true)

    {result, events} =
      TelemetryHelper.capture([@event], fn ->
        Telemetry.execute(@event, %{count: 1}, result: :ok)
      end)

    assert result == :ok
    assert [%{measurements: %{count: 1}, metadata: %{result: :ok}}] = events
  end

  test "execute/3 does nothing when telemetry is disabled" do
    Application.put_env(:spectre_kinetic, :telemetry_enabled, false)

    {result, events} =
      TelemetryHelper.capture([@event], fn ->
        Telemetry.execute(@event, %{count: 1})
      end)

    assert result == :ok
    assert events == []
  end
end
