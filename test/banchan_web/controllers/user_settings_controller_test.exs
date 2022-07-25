defmodule BanchanWeb.UserSettingsControllerTest do
  use BanchanWeb.ConnCase, async: true

  use Bamboo.Test

  alias Banchan.Accounts
  import Banchan.AccountsFixtures

  setup :register_and_log_in_user

  describe "/settings (basics)" do
    test "renders settings page", %{conn: conn} do
      conn = get(conn, Routes.settings_path(conn, :edit))
      response = html_response(conn, 200)
      assert response =~ "Account Settings</h1>"
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      conn = get(conn, Routes.settings_path(conn, :edit))
      assert redirected_to(conn) == Routes.login_path(conn, :new)
    end
  end

  describe "GET /settings/confirm_email/:token" do
    setup %{user: user} do
      email = unique_user_email()

      {:ok, %Oban.Job{}} =
        Accounts.deliver_update_email_instructions(
          %{user | email: email},
          user.email,
          &extractable_user_token/1
        )

      assert_delivered_email_matches(%{
        html_body: html_body
      })

      token = extract_user_token(html_body)

      %{token: token, email: email}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      conn = get(conn, Routes.user_settings_path(conn, :confirm_email, token))
      assert redirected_to(conn) == Routes.settings_path(conn, :edit)
      assert get_flash(conn, :info) =~ "Email changed successfully"
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      conn = get(conn, Routes.user_settings_path(conn, :confirm_email, token))
      assert redirected_to(conn) == Routes.settings_path(conn, :edit)
      assert get_flash(conn, :error) =~ "Email change link is invalid or it has expired"
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      conn = get(conn, Routes.user_settings_path(conn, :confirm_email, "oops"))
      assert redirected_to(conn) == Routes.settings_path(conn, :edit)
      assert get_flash(conn, :error) =~ "Email change link is invalid or it has expired"
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      conn = get(conn, Routes.user_settings_path(conn, :confirm_email, token))
      assert redirected_to(conn) == Routes.login_path(conn, :new)
    end
  end
end
