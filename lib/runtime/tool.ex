defmodule SpectreKinetic.Tool do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use SpectreKinetic
    end
  end
end
