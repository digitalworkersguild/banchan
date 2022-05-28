defmodule BanchanWeb.StudioLive.Payouts do
  @moduledoc """
  Studio payouts page.
  """
  use BanchanWeb, :surface_view

  import BanchanWeb.StudioLive.Helpers

  alias Banchan.Studios

  alias BanchanWeb.CommissionLive.Components.StudioLayout

  def mount(params, _session, socket) do
    socket = assign_studio_defaults(params, socket, true, false)

    {:ok,
     socket
     |> assign(balance: Studios.get_banchan_balance!(socket.assigns.studio))}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(uri: uri)}
  end

  @impl true
  def handle_event("pay_me", _, socket) do
    case Studios.payout_studio(socket.assigns.studio) do
      {:ok, _payouts} ->
        {:noreply,
         socket
         |> put_flash(
           :success,
           "Payouts sent! It may be a few days before they arrive in your account."
         )
         |> assign(balance: Studios.get_banchan_balance!(socket.assigns.studio))}

      {:error, user_msg} ->
        {:noreply,
         socket
         |> put_flash(:error, user_msg)
         |> assign(balance: Studios.get_banchan_balance!(socket.assigns.studio))}
    end
  end

  @impl true
  def render(assigns) do
    ~F"""
    <StudioLayout
      current_user={@current_user}
      flashes={@flash}
      studio={@studio}
      current_user_member?={@current_user_member?}
      tab={:settings}
      uri={@uri}
    >
      <div class="mx-auto">
        <div class="stats stats-vertical">
          <div class="stat">
            <div class="stat-title">
              Available for Payout
            </div>
            <div class="stat-value">
              {Enum.join(
                Enum.map(
                  @balance.available,
                  &Money.to_string/1
                ),
                " + "
              )}
            </div>
            <div class="stat-desc">
              Approved for release and ready on Stripe.
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">
              Released from Commissions
            </div>
            <div class="stat-value">
              {Enum.join(
                Enum.map(
                  @balance.released,
                  &Money.to_string/1
                ),
                " + "
              )}
            </div>
            <div class="stat-desc">
              Approved for release by clients.
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">
              Held by Banchan
            </div>
            <div class="stat-value">
              {Enum.join(
                Enum.map(
                  @balance.held_back,
                  &Money.to_string/1
                ),
                " + "
              )}
            </div>
            <div class="stat-desc">
              Paid into Banchan but not released.
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">
              Pending on Stripe
            </div>
            <div class="stat-value">
              {Enum.join(
                Enum.map(
                  @balance.stripe_pending,
                  &Money.to_string(&1)
                ),
                " + "
              )}
            </div>
            <div class="stat-desc">
              Includes both for released and pending payments.
            </div>
          </div>
        </div>
      </div>
    </StudioLayout>
    """
  end
end
