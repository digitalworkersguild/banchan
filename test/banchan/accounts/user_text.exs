defmodule Banchan.AccountsTest.Confirmation do
  @moduledoc """
  Tests for functionality related to the User schema.
  """
  use Banchan.DataCase, async: true

  alias Banchan.Accounts.User

  describe "inspect/2" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end
end
