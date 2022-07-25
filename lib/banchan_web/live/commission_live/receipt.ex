defmodule BanchanWeb.CommissionLive.Receipt do
  @moduledoc """
  Plain ol' view to render invoice receipts.
  """
  use BanchanWeb, :surface_view

  alias Banchan.Commissions
  alias Banchan.Repo

  def mount(%{"commission_id" => public_comm_id, "event_id" => public_ev_id}, _, socket) do
    comm = Commissions.get_commission!(public_comm_id, socket.assigns.current_user)
    ev = Enum.find(comm.events, &(&1.public_id == public_ev_id))
    invoice = ev.invoice |> Repo.preload(:event)
    deposited = Commissions.deposited_amount(socket.assigns.current_user, comm, true)
    tipped = Commissions.tipped_amount(socket.assigns.current_user, comm, true)

    {:ok,
     socket
     |> assign(
       commission: comm,
       deposited: deposited,
       tipped: tipped,
       invoice: invoice
     )}
  end

  def render(assigns) do
    ~F"""
    <div class="prose">
      {raw(Phoenix.View.render_to_string(BanchanWeb.Email.CommissionsView, "receipt.html", assigns))}
    </div>
    """
  end
end
