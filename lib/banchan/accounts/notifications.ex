defmodule Banchan.Accounts.Notifications do
  @moduledoc """
  Notifications for account events.
  """
  import Ecto.Query, warn: false

  alias Banchan.Workers.Mailer

  @doc """
  Deliver instructions to confirm account.
  """
  def confirmation_instructions(user, url) do
    Mailer.new_email(
      user.email,
      "Confirm Your Banchan Art Email",
      BanchanWeb.Email.AccountsView,
      :confirmation_instructions,
      user: user,
      url: url
    )
    |> Mailer.deliver()
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def reset_password_instructions(user, url) do
    Mailer.new_email(
      user.email,
      "Reset Your Banchan Art Email",
      BanchanWeb.Email.AccountsView,
      :reset_password_instructions,
      user: user,
      url: url
    )
    |> Mailer.deliver()
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def update_email_instructions(user, url) do
    Mailer.new_email(
      user.email,
      "Update Your Banchan Art Email",
      BanchanWeb.Email.AccountsView,
      :update_email_instructions,
      user: user,
      url: url
    )
    |> Mailer.deliver()
  end
end
