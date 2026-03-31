defmodule SpectreKinetic.Native do
  @moduledoc false

  use Rustler, otp_app: :spectre_kinetic, crate: :spectre_ffi

  def open(_model_dir, _registry_mcr), do: :erlang.nif_error(:nif_not_loaded)
  def plan(_handle, _al_text), do: :erlang.nif_error(:nif_not_loaded)
  def plan_al(_handle, _al_text), do: :erlang.nif_error(:nif_not_loaded)
  def plan_json(_handle, _request_json), do: :erlang.nif_error(:nif_not_loaded)
  def add_action(_handle, _action_json), do: :erlang.nif_error(:nif_not_loaded)
  def delete_action(_handle, _action_id), do: :erlang.nif_error(:nif_not_loaded)
  def load_registry(_handle, _registry_mcr), do: :erlang.nif_error(:nif_not_loaded)
  def action_count(_handle), do: :erlang.nif_error(:nif_not_loaded)
  def version, do: :erlang.nif_error(:nif_not_loaded)
end
