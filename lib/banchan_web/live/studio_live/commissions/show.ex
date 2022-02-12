defmodule BanchanWeb.StudioLive.Commissions.Show do
  @moduledoc """
  Subpage for commissions themselves. This is where the good stuff happens.
  """
  use BanchanWeb, :surface_view

  alias Banchan.Commissions
  alias Banchan.Commissions.LineItem

  alias BanchanWeb.StudioLive.Components.Commissions.{
    CommentBox,
    RequestPayment,
    Status,
    Summary,
    Timeline
  }

  alias BanchanWeb.StudioLive.Components.StudioLayout

  import BanchanWeb.StudioLive.Helpers

  @impl true
  def mount(%{"commission_id" => commission_id} = params, session, socket) do
    socket = assign_defaults(session, socket, true)
    socket = assign_studio_defaults(params, socket, false, false)

    commission =
      Commissions.get_commission!(
        socket.assigns.studio,
        commission_id,
        socket.assigns.current_user,
        socket.assigns.current_user_member?
      )

    Commissions.subscribe_to_commission_events(commission)

    custom_changeset =
      if socket.assigns.current_user_member? do
        %LineItem{} |> LineItem.custom_changeset(%{})
      else
        nil
      end

    {:ok,
     socket
     |> assign(commission: commission, custom_changeset: custom_changeset, open_custom: false)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(uri: uri)}
  end

  @impl true
  def handle_info(%{event: "new_events", payload: events}, socket) do
    events = socket.assigns.commission.events ++ events
    events = events |> Enum.sort_by(& &1.inserted_at)
    commission = %{socket.assigns.commission | events: events}
    {:noreply, assign(socket, commission: commission)}
  end

  def handle_info(%{event: "line_items_changed", payload: line_items}, socket) do
    {:noreply, assign(socket, commission: %{socket.assigns.commission | line_items: line_items})}
  end

  def handle_info(%{event: "new_status", payload: status}, socket) do
    commission = %{socket.assigns.commission | status: status}
    {:noreply, assign(socket, commission: commission)}
  end

  @impl true
  def handle_event("add_item", %{"value" => idx}, socket) do
    {idx, ""} = Integer.parse(idx)

    commission = socket.assigns.commission

    option =
      if commission.offering do
        {:ok, option} = Enum.fetch(commission.offering.options, idx)
        option
      else
        %{
          # TODO: fill this out?
        }
      end

    if !socket.assigns.current_user_member? ||
         (!option.multiple &&
            Enum.any?(commission.line_items, &(&1.option && &1.option.id == option.id))) do
      # Deny the change. This shouldn't happen unless there's a bug, or
      # someone is trying to send us Shenanigans data.
      {:noreply, socket}
    else
      {:ok, {commission, _events}} =
        Commissions.add_line_item(socket.assigns.current_user, commission, option)

      {:noreply, assign(socket, commission: commission)}
    end
  end

  def handle_event("remove_item", %{"value" => idx}, socket) do
    {idx, ""} = Integer.parse(idx)
    line_item = Enum.at(socket.assigns.commission.line_items, idx)

    if socket.assigns.current_user_member? && line_item && !line_item.sticky do
      {:ok, {commission, _events}} =
        Commissions.remove_line_item(
          socket.assigns.current_user,
          socket.assigns.commission,
          line_item
        )

      {:noreply, assign(socket, commission: commission)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_custom", _, socket) do
    {:noreply, assign(socket, open_custom: !socket.assigns.open_custom)}
  end

  def handle_event(
        "change_custom",
        %{"line_item" => %{"name" => name, "description" => description, "amount" => amount}},
        socket
      ) do
    changeset =
      %LineItem{}
      |> LineItem.custom_changeset(%{
        name: name,
        description: description,
        amount: moneyfy(amount)
      })
      |> Map.put(:action, :insert)

    {:noreply, socket |> assign(:custom_changeset, changeset)}
  end

  def handle_event(
        "submit_custom",
        %{"line_item" => %{"name" => name, "description" => description, "amount" => amount}},
        socket
      ) do
    commission = socket.assigns.commission

    if socket.assigns.current_user_member? do
      {:ok, {commission, _events}} =
        Commissions.add_line_item(socket.assigns.current_user, commission, %{
          name: name,
          description: description,
          amount: moneyfy(amount)
        })

      {:noreply,
       assign(socket,
         commission: commission,
         custom_changeset: %LineItem{} |> LineItem.custom_changeset(%{})
       )}
    else
      # Deny the change. This shouldn't happen unless there's a bug, or
      # someone is trying to send us Shenanigans data.
      {:noreply, socket}
    end
  end

  def handle_event("update-status", %{"status" => [new_status]}, socket) do
    comm = %{socket.assigns.commission | tos_ok: true}

    {:ok, {commission, _events}} =
      Commissions.update_status(socket.assigns.current_user, comm, new_status)

    {:noreply, socket |> assign(commission: commission)}
  end

  defp moneyfy(amount) do
    # TODO: In the future, we can replace this :USD with a param and the DB will be fine.
    case Money.parse(amount, :USD) do
      {:ok, money} ->
        money

      :error ->
        amount
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
      tab={:shop}
    >
      <div>
        <h1 class="text-3xl">{@commission.title}</h1>
        <hr>
        <div class="commission grid gap-4">
          <div class="col-span-10">
            <div class="p-4">
              <Timeline
                uri={@uri}
                studio={@studio}
                commission={@commission}
                current_user={@current_user}
                current_user_member?={@current_user_member?}
              />
            </div>
            <div class="p-4">
              <CommentBox id="comment-box" commission={@commission} actor={@current_user} />
            </div>
          </div>
          <div class="col-span-2 col-end-13 p-6">
            <div id="sidebar">
              <div class="block sidebar-box">
                <Summary
                  line_items={@commission.line_items}
                  offering={@commission.offering}
                  allow_edits={@current_user_member?}
                  add_item="add_item"
                  remove_item="remove_item"
                  custom_changeset={@custom_changeset}
                  open_custom={@open_custom}
                  toggle_custom="toggle_custom"
                  change_custom="change_custom"
                  submit_custom="submit_custom"
                />
              </div>
              <div class="block sidebar-box">
                <Status commission={@commission} editable={@current_user_member?} change="update-status" />
              </div>
              {#if @current_user_member?}
                <div class="block sidebar-box">
                  <RequestPayment id="request_payment" current_user={@current_user} commission={@commission} />
                </div>
              {/if}
            </div>
          </div>
        </div>
      </div>
    </StudioLayout>
    """
  end
end
