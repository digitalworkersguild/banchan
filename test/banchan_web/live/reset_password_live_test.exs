defmodule BanchanWeb.ResetPasswordLiveTest do
  use BanchanWeb.ConnCase

  use Bamboo.Test

  import Phoenix.LiveViewTest
  import Banchan.AccountsFixtures
  alias Banchan.Accounts

  setup do
    user = user_fixture()

    {:ok, %Oban.Job{}} =
      Accounts.deliver_user_reset_password_instructions(user, &extractable_user_token/1)

    assert_delivered_email_matches(%{
      html_body: html_body
    })

    token = extract_user_token(html_body)

    %{user: user, token: token}
  end

  test "renders reset password", %{conn: conn, token: token} do
    {:ok, _view, html} = live(conn, Routes.reset_password_path(conn, :edit, token))
    assert html =~ "Reset Password"
  end

  test "does not render reset password with invalid token", %{conn: conn} do
    {:ok, _view, html} =
      live(conn, Routes.reset_password_path(conn, :edit, "oops"))
      |> follow_redirect(conn, Routes.home_path(conn, :index))

    assert html =~ "Reset password link is invalid or it has expired"
  end

  test "resets password once", %{conn: conn, user: user, token: token} do
    {:ok, view, _html} = live(conn, Routes.reset_password_path(conn, :edit, token))

    {:ok, _view, html} =
      view
      |> form("form",
        user: %{password: "new valid password", password_confirmation: "new valid password"}
      )
      |> render_submit()
      |> follow_redirect(conn, Routes.login_path(conn, :new))

    # TODO: Figure out how to check this.
    # refute get_session(conn, :user_token)
    assert html =~ "Password reset successfully"
    assert Accounts.get_user_by_identifier_and_password(user.email, "new valid password")
  end

  test "does not reset password on invalid data", %{conn: conn, token: token} do
    {:ok, view, _html} = live(conn, Routes.reset_password_path(conn, :edit, token))

    html =
      view
      |> form("form",
        user: %{password: "too short", password_confirmation: "does not match"}
      )
      |> render_submit()

    assert html =~ "Reset Password"
    assert html =~ "should be at least 12 character(s)"
    assert html =~ "does not match password"
  end
end
