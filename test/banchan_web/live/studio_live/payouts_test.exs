defmodule BanchanWeb.StudioLive.PayoutsTest do
  @moduledoc """
  Tests for the studio payouts management page(s).
  """
  use BanchanWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  import Banchan.CommissionsFixtures

  alias Banchan.Studios

  defp mock_balance(studio, available, pending, n \\ 2) do
    Banchan.StripeAPI.Mock
    |> expect(:retrieve_balance, n, fn opts ->
      assert %{"Stripe-Account" => studio.stripe_id} == Keyword.get(opts, :headers)

      {:ok,
       %Stripe.Balance{
         available:
           Enum.map(
             available,
             &%{
               currency: String.downcase(to_string(&1.currency)),
               amount: &1.amount
             }
           ),
         pending:
           Enum.map(
             pending,
             &%{
               currency: String.downcase(to_string(&1.currency)),
               amount: &1.amount
             }
           )
       }}
    end)
  end

  setup do
    commission = commission_fixture()

    %{
      commission: commission,
      client: commission.client,
      studio: commission.studio,
      artist: Enum.at(commission.studio.artists, 0)
    }
  end

  describe "base page behaviors" do
    test "redirects if logged out", %{conn: conn, studio: studio} do
      {:error, {:redirect, info}} =
        live(conn, Routes.studio_payouts_path(conn, :show, studio.handle))

      assert info.to =~ Routes.login_path(conn, :new)
    end

    test "redirects if stripe not enabled", %{conn: conn, studio: studio, artist: artist} do
      conn = log_in_user(conn, artist)

      {:error, {:redirect, info}} =
        result = live(conn, Routes.studio_payouts_path(conn, :show, studio.handle))

      assert info.to =~ Routes.studio_shop_path(conn, :show, studio.handle)

      {:ok, conn} = follow_redirect(result, conn)

      {:ok, page_live, _html} = live(conn)

      assert page_live
             |> element(".flash-container")
             |> render() =~ "This studio is not ready to accept commissions yet."
    end

    test "404 if user is not a member", %{conn: conn, client: client, studio: studio} do
      conn = log_in_user(conn, client)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, Routes.studio_payouts_path(conn, :show, studio.handle))
      end
    end
  end

  describe "listing payouts" do
  end

  describe "view stats" do
    setup %{conn: conn, studio: studio, artist: artist} do
      Studios.update_stripe_state!(studio.stripe_id, %Stripe.Account{
        charges_enabled: true,
        details_submitted: true
      })

      %{conn: log_in_user(conn, artist)}
    end

    test "shows default stats if no commissions or payouts", %{conn: conn, studio: studio} do
      mock_balance(studio, [], [])

      # TODO: This should be a separate, dedicated path (like with the Commissions page)
      {:ok, page_live, _html} = live(conn, Routes.studio_payouts_path(conn, :show, studio.handle))

      assert page_live
             |> element("#available")
             |> render() =~ "$0.00"

      assert page_live
             |> element("#held-back")
             |> render() =~ "$0.00"

      assert page_live
             |> element("#on-the-way")
             |> render() =~ "$0.00"
    end
  end

  describe "trigger payout" do
  end
end
