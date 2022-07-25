defmodule Banchan.AccountsTest.Fetch do
  @moduledoc """
  Tests for functionality related to reading/fetching account information/
  """
  use Banchan.DataCase, async: true

  alias Banchan.Accounts
  import Banchan.AccountsFixtures
  alias Banchan.Accounts.User

  describe "get_user_by_handle/1" do
    test "does not return the user if the handle does not exist" do
      catch_error(Accounts.get_user_by_handle!("unknown"))
    end

    test "returns the user if the email exists" do
      %{id: id} = user = unconfirmed_user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_handle!(user.handle)
    end
  end

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = unconfirmed_user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_identifier_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_identifier_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = unconfirmed_user_fixture()
      refute Accounts.get_user_by_identifier_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = unconfirmed_user_fixture()

      assert %User{id: ^id} =
               Accounts.get_user_by_identifier_and_password(user.email, valid_user_password())
    end
  end
end
