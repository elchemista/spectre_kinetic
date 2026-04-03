defmodule SpectreKinetic.ToolFixtures.Emailer do
  @moduledoc false
  use SpectreKinetic

  @al ~s(SEND EMAIL TO=email@gmail.com BODY=text)
  @doc """
  Send an email to a recipient.

  AL: SEND EMAIL TO="dev@example.com" BODY="hello"
  AL: SEND MAIL TO="ops@example.com" BODY="pager"
  """
  @spec send(email :: String.t(), text :: String.t()) :: {:ok, String.t()} | {:error, term()}
  def send(email, text) do
    {:ok, "#{email}:#{text}"}
  end
end

defmodule SpectreKinetic.ToolFixtures.Sms do
  @moduledoc false
  use SpectreKinetic

  @al ~s(SEND SMS TO=+15551234567 BODY=text)
  @doc """
  Send an SMS message.

  AL: SEND SMS TO="+15551234567" BODY="hello"
  """
  @spec send(to :: String.t(), body :: String.t()) :: :ok
  def send(to, body) do
    _ = {to, body}
    :ok
  end
end
