defmodule SpectreKinetic.Server do
  @moduledoc """
  Backward-compatible facade for the optional planner `GenServer` adapter.

  The library-first API works with `SpectreKinetic.Planner.Runtime` structs.
  This module keeps the older server-oriented entry point available while
  delegating all behavior to `SpectreKinetic.Adapter.Server`.
  """

  alias SpectreKinetic.Adapter.Server, as: AdapterServer

  defdelegate start_link(opts \\ []), to: AdapterServer
  defdelegate plan(server, al_text, opts \\ []), to: AdapterServer
  defdelegate plan_request(server, request), to: AdapterServer
  defdelegate plan_json(server, request_json), to: AdapterServer
  defdelegate add_action(server, action), to: AdapterServer
  defdelegate delete_action(server, action_id), to: AdapterServer
  defdelegate reload_registry(server, registry_path), to: AdapterServer
  defdelegate action_count(server), to: AdapterServer
end
