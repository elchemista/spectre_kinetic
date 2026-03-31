defmodule SpectreKinetic.Native do
  @moduledoc false

  use Rustler, otp_app: :spectre_kinetic, crate: :spectre_ffi

  @doc false
  @spec open(binary(), binary()) :: reference() | {:error, term()} | no_return()
  def open(_model_dir, _registry_mcr), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec plan(reference(), binary()) :: binary() | no_return()
  def plan(_handle, _al_text), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec plan_al(reference(), binary()) :: binary() | no_return()
  def plan_al(_handle, _al_text), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec plan_json(reference(), binary()) :: binary() | {:error, term()} | no_return()
  def plan_json(_handle, _request_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec add_action(reference(), binary()) :: boolean() | {:error, term()} | no_return()
  def add_action(_handle, _action_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec delete_action(reference(), binary()) :: boolean() | {:error, term()} | no_return()
  def delete_action(_handle, _action_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec load_registry(reference(), binary()) :: boolean() | {:error, term()} | no_return()
  def load_registry(_handle, _registry_mcr), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec action_count(reference()) :: non_neg_integer() | no_return()
  def action_count(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec version() :: binary() | no_return()
  def version, do: :erlang.nif_error(:nif_not_loaded)
end
