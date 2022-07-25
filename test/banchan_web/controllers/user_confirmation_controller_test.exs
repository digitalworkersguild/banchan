defmodule BanchanWeb.UserConfirmationControllerTest do
  use BanchanWeb.ConnCase, async: true

  use Bamboo.Test

  alias Banchan.Accounts
  alias Banchan.Repo
  import Banchan.AccountsFixtures

  setup do
    %{user: unconfirmed_user_fixture()}
  end

  describe "/confirm" do
    test "renders the confirmation page", %{conn: conn} do
      conn = get(conn, Routes.confirmation_path(conn, :show))
      response = html_response(conn, 200)
      assert response =~ "Email confirmation will be sent again"
    end
  end

  describe "GET /users/confirm/:token" do
    test "confirms the given token once", %{conn: conn, user: user} do
      {:ok, %Oban.Job{}} =
        Accounts.deliver_user_confirmation_instructions(user, &extractable_user_token/1)

      assert_delivered_email_matches(%{
        html_body: html_body
      })

      token = extract_user_token(html_body)

      conn = get(conn, Routes.user_confirmation_path(conn, :confirm, token))
      assert redirected_to(conn) == "/"
      assert get_flash(conn, :info) =~ "User confirmed successfully"
      assert Accounts.get_user!(user.id).confirmed_at
      refute get_session(conn, :user_token)
      assert Repo.all(Accounts.UserToken) == []

      # When not logged in
      conn = get(conn, Routes.user_confirmation_path(conn, :confirm, token))
      assert redirected_to(conn) == "/"
      assert get_flash(conn, :error) =~ "User confirmation link is invalid or it has expired"

      # When logged in
      conn =
        build_conn()
        |> log_in_user(user)
        |> get(Routes.user_confirmation_path(conn, :confirm, token))

      assert redirected_to(conn) == "/"
      refute get_flash(conn, :error)
    end

    test "does not confirm email with invalid token", %{conn: conn, user: user} do
      conn = get(conn, Routes.user_confirmation_path(conn, :confirm, "oops"))
      assert redirected_to(conn) == "/"
      assert get_flash(conn, :error) =~ "User confirmation link is invalid or it has expired"
      refute Accounts.get_user!(user.id).confirmed_at
    end
  end
end
