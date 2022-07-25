defmodule Banchan.AccountsTest.Settings do
  @moduledoc """
  Tests for functionality related to user settings and profile management.
  """
  use Banchan.DataCase, async: true

  use Bamboo.Test

  alias Banchan.Accounts
  import Banchan.AccountsFixtures
  alias Banchan.Accounts.{User, UserToken}

  describe "change_user_handle/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = Accounts.change_user_handle(%User{})
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_handle(%User{}, %{
          "handle" => "newhandle"
        })

      assert changeset.valid?
      assert get_change(changeset, :handle) == "newhandle"
    end
  end

  describe "update_user_handle/3" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "validates handle", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_handle(user, valid_user_password(), %{
          handle: "b"
        })

      assert %{
               handle: ["should be at least 3 character(s)"]
             } = errors_on(changeset)

      {:error, changeset} =
        Accounts.update_user_handle(user, valid_user_password(), %{
          handle: "bad handle"
        })

      assert %{
               handle: ["only letters, numbers, and underscores allowed"]
             } = errors_on(changeset)
    end
  end

  describe "change_user_email/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "apply_user_email/3" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "validates email", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum value for email for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness", %{user: user} do
      %{email: email} = unconfirmed_user_fixture()

      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: email})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, "invalid", %{email: unique_user_email()})

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "applies the email without persisting it", %{user: user} do
      email = unique_user_email()
      {:ok, user} = Accounts.apply_user_email(user, valid_user_password(), %{email: email})
      assert user.email == email
      assert Accounts.get_user!(user.id).email != email
    end
  end

  describe "deliver_update_email_instructions/3" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      Accounts.deliver_update_email_instructions(
        user,
        "current@example.com",
        &extractable_user_token/1
      )

      email = user.email

      assert_delivered_email_matches(%_{
        to: [{_, ^email}],
        subject: "Update Your Banchan Art Email",
        text_body: text_body,
        html_body: html_body
      })

      token = extract_user_token(text_body)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"

      token = extract_user_token(html_body)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
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

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert Accounts.update_user_email(user, token) == :ok
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      assert changed_user.confirmed_at
      assert changed_user.confirmed_at != user.confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert Accounts.update_user_email(user, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(%User{}, %{
          "password" => "new valid password"
        })

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/3" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{password: too_long})

      assert "should be at most 80 character(s)" in errors_on(changeset).password
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, "invalid", %{password: valid_user_password()})

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "updates the password", %{user: user} do
      {:ok, user} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      assert is_nil(user.password)
      assert Accounts.get_user_by_identifier_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, _} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "update_user_profile/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "validates profile", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_profile(
          user,
          user,
          %{
            name: String.duplicate("b", 40),
            bio: String.duplicate("a", 461)
          }
        )

      assert %{
               bio: ["should be at most 160 character(s)"],
               name: ["should be at most 32 character(s)"]
             } = errors_on(changeset)
    end

    test "updates the user profile", %{user: user} do
      {:ok, user} =
        Accounts.update_user_profile(
          user,
          user,
          %{
            handle: "newhandle",
            name: "New Name",
            bio: "New Bio"
          }
        )

      assert Accounts.get_user_by_handle!(user.handle)
    end
  end
end
