defmodule SpectreKinetic.Helper do
  @moduledoc """
  Build-time and offline tooling helpers used by mix tasks.
  """

  @app :spectre_kinetic

  @doc """
  Returns the project root used for helper task execution.
  """
  @spec app_root() :: binary()
  def app_root do
    Path.expand("..", __DIR__)
  end

  @doc """
  Returns the path to the native Rust `Cargo.toml`.
  """
  @spec native_manifest_path() :: binary()
  def native_manifest_path do
    Path.join(app_root(), "native/spectre_ffi/Cargo.toml")
  end

  @doc """
  Returns whether helper tasks should run with `cargo run --release`.
  """
  @spec release?() :: boolean()
  def release? do
    Application.get_env(@app, :helper_release?, false) or
      System.get_env("SPECTRE_KINETIC_HELPER_RELEASE") == "1"
  end

  @doc """
  Runs the Rust helper binary with the given subcommand and arguments.
  """
  @spec run!(binary(), [binary()]) :: :ok
  def run!(subcommand, args) when is_binary(subcommand) and is_list(args) do
    cargo =
      System.find_executable("cargo") ||
        raise ArgumentError, "`cargo` is required to run spectre helper tasks."

    command =
      ["run"]
      |> maybe_add_release()
      |> Kernel.++([
        "--manifest-path",
        native_manifest_path(),
        "--features",
        "helper",
        "--bin",
        "spectre_kinetic_helper",
        "--",
        subcommand
      ])
      |> Kernel.++(args)

    {_output, status} =
      System.cmd(cargo, command,
        cd: app_root(),
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    case status do
      0 -> :ok
      _ -> raise RuntimeError, "spectre helper task failed with exit status #{status}"
    end
  end

  defp maybe_add_release(command) do
    if release?(), do: command ++ ["--release"], else: command
  end
end
