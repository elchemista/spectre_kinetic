defmodule SpectreKinetic do
  @moduledoc """
  Elixir wrapper for spectre-kinetic — deterministic, zero-LLM action dispatch.

  Uses Rustler NIFs to call the Rust spectre-core engine for sub-millisecond
  action planning via cosine similarity over static token embeddings.
  """

  alias SpectreKinetic.Server

  @doc """
  Starts the SpectreKinetic server.

  ## Options

    * `:model_dir` — path to the trained model pack directory (required)
    * `:registry_mcr` — path to the compiled `.mcr` registry file (required)
    * `:name` — GenServer name (defaults to `SpectreKinetic.Server`)

  """
  defdelegate start_link(opts), to: Server

  @doc """
  Plans an action from an AL (Action Language) statement.

  Returns a decoded map with keys like `"status"`, `"selected_tool"`,
  `"confidence"`, `"args"`, `"candidates"`, and `"suggestions"`.
  """
  @spec plan(GenServer.server(), binary()) :: {:ok, map()} | {:error, term()}
  def plan(server \\ Server, al_text) when is_binary(al_text) do
    Server.plan(server, al_text)
  end

  @doc """
  Plans an action from a full PlanRequest JSON string.
  """
  @spec plan_json(GenServer.server(), binary()) :: {:ok, map()} | {:error, term()}
  def plan_json(server \\ Server, request_json) when is_binary(request_json) do
    Server.plan_json(server, request_json)
  end

  @doc """
  Registers a new action at runtime.

  `action` is a map matching the ToolDef schema (id, module, name, arity, doc, spec, args, examples).
  """
  @spec add_action(GenServer.server(), map()) :: :ok | {:error, term()}
  def add_action(server \\ Server, action) when is_map(action) do
    Server.add_action(server, action)
  end

  @doc """
  Removes a registered action by its id.
  """
  @spec delete_action(GenServer.server(), binary()) :: {:ok, boolean()} | {:error, term()}
  def delete_action(server \\ Server, action_id) when is_binary(action_id) do
    Server.delete_action(server, action_id)
  end

  @doc """
  Hot-swaps the active registry without restarting the server.
  """
  @spec reload_registry(GenServer.server(), binary()) :: :ok | {:error, term()}
  def reload_registry(server \\ Server, registry_path) when is_binary(registry_path) do
    Server.reload_registry(server, registry_path)
  end

  @doc """
  Returns the number of actions in the current registry.
  """
  @spec action_count(GenServer.server()) :: non_neg_integer()
  def action_count(server \\ Server) do
    Server.action_count(server)
  end

  @doc """
  Returns the spectre-ffi version string.
  """
  @spec version() :: binary()
  def version do
    SpectreKinetic.Native.version()
  end
end
