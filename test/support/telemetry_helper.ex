defmodule SpectreKinetic.TelemetryHelper do
  @moduledoc false

  def capture(events, fun) when is_list(events) and is_function(fun, 0) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler_id,
      events,
      &__MODULE__.handle_event/4,
      %{handler_id: handler_id, test_pid: test_pid}
    )

    try do
      result = fun.()
      {result, collect_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  def handle_event(event, measurements, metadata, %{
        handler_id: handler_id,
        test_pid: test_pid
      }) do
    send(test_pid, {handler_id, event, measurements, metadata})
  end

  defp collect_events(handler_id, acc) do
    receive do
      {^handler_id, event, measurements, metadata} ->
        collect_events(handler_id, [
          %{event: event, measurements: measurements, metadata: metadata} | acc
        ])
    after
      0 ->
        Enum.reverse(acc)
    end
  end
end
