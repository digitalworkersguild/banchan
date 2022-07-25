defmodule Banchan.AccountsTest.Confirmation do
  @moduledoc """
  Tests for functionality related to user confirmation.
  """
  use Banchan.DataCase, async: true

  use Bamboo.Test

  alias Banchan.Accounts
  import Banchan.AccountsFixtures
  alias Banchan.Accounts.{User, UserToken}

  describe "deliver_user_confirmation_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      {:ok, %Oban.Job{}} =
        Accounts.deliver_user_confirmation_instructions(user, &extractable_user_token/1)

      email = user.email

      assert_delivered_email_matches(%{
        to: [{_, ^email}],
        subject: "Confirm Your Banchan Art Email",
        text_body: text_body,
        html_body: html_body
      })

      token = extract_user_token(text_body)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "confirm"

      token = extract_user_token(html_body)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "confirm"
    end
  end

  describe "confirm_user/1" do
    setup do
      user = unconfirmed_user_fixture()

      {:ok, %Oban.Job{}} =
        Accounts.deliver_user_confirmation_instructions(user, &extractable_user_token/1)

      assert_delivered_email_matches(%{
        html_body: html_body
      })

      token = extract_user_token(html_body)

      %{user: user, token: token}
    end

    test "confirms the email with a valid token", %{user: user, token: token} do
      assert {:ok, confirmed_user} = Accounts.confirm_user(token)
      assert confirmed_user.confirmed_at
      assert confirmed_user.confirmed_at != user.confirmed_at
      assert Repo.get!(User, user.id).confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm with invalid token", %{user: user} do
      assert Accounts.confirm_user("oops") == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert Accounts.confirm_user(token) == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end
end
