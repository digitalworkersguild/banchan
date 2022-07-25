defmodule BanchanWeb.Email.AccountsView do
  @moduledoc """
  Rendering emails related to the Accounts context.
  """
  use BanchanWeb, :view

  def render("confirmation_instructions.html", assigns) do
    ~F"""
    <p>Hi {@user.name || @user.handle}!</p>
    <p>You can confirm your email address by
      <a href={@url}>clicking here</a> or visiting the following URL:
    </p>
    <p>{@url}</p>
    <p>If you didn't create an account with us please ignore this.</p>
    """
  end

  def render("confirmation_instructions.text", assigns) do
    """
    ==============================

    Hi #{assigns.user.name || assigns.user.handle},

    You can confirm your account by visiting the URL below:

    #{assigns.url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """
  end

  def render("reset_password_instructions.html", assigns) do
    ~F"""
    <p>Hi {@user.name || @user.handle}!</p>
    <p>You can reset your password by
      <a href={@url}>clicking here</a> or visiting the following URL:
    </p>
    <p>{@url}</p>
    <p>If you didn't request this change, please ignore this.</p>
    """
  end

  def render("reset_password_instructions.text", assigns) do
    """
    ==============================

    Hi #{assigns.user.name || assigns.user.handle},

    You can reset your password by visiting the URL below:

    #{assigns.url}

    If you didn't request this change, please ignore this.

    ==============================
    """
  end

  def render("update_email_instructions.html", assigns) do
    ~F"""
    <p>Hi {@user.name || @user.handle}!</p>
    <p>You can change your email by
      <a href={@url}>clicking here</a> or visiting the following URL:
    </p>
    <p>{@url}</p>
    <p>If you didn't request this change, please ignore this.</p>
    """
  end

  def render("update_email_instructions.text", assigns) do
    """
    ==============================

    Hi #{assigns.user.name || assigns.user.handle},

    You can change your email by visiting the URL below:

    #{assigns.url}

    If you didn't request this change, please ignore this.

    ==============================
    """
  end
end
