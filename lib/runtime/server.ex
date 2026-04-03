defmodule SpectreKinetic.Server do
  @moduledoc false

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
