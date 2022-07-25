defmodule Banchan.Commissions.Notifications do
  @moduledoc """
  Notifications for commission events.
  """
  import Ecto.Query, warn: false

  alias Banchan.Accounts.User
  alias Banchan.Commissions
  alias Banchan.Commissions.{Commission, CommissionSubscription, Common, Event, Invoice}
  alias Banchan.Notifications
  alias Banchan.Repo
  alias Banchan.Studios
  alias Banchan.Studios.{Studio, StudioSubscription}
  alias Banchan.Workers.Mailer

  # Unfortunate, but needed for crafting URLs for notifications
  alias BanchanWeb.Endpoint
  alias BanchanWeb.Router.Helpers, as: Routes

  @pubsub Banchan.PubSub

  def user_subscribed?(%User{} = user, %Commission{} = commission) do
    from(sub in CommissionSubscription,
      where:
        sub.user_id == ^user.id and sub.commission_id == ^commission.id and sub.silenced != true
    )
    |> Repo.exists?()
  end

  def subscribe_user!(%User{} = user, %Commission{} = comm) do
    %CommissionSubscription{user_id: user.id, commission_id: comm.id, silenced: false}
    |> Repo.insert(
      on_conflict: {:replace, [:silenced]},
      conflict_target: [:user_id, :commission_id]
    )
  end

  def unsubscribe_user!(%User{} = user, %Commission{} = comm) do
    %CommissionSubscription{user_id: user.id, commission_id: comm.id, silenced: true}
    |> Repo.insert(
      on_conflict: {:replace, [:silenced]},
      conflict_target: [:user_id, :commission_id]
    )
  end

  def subscribers(%Commission{} = commission) do
    from(
      u in User,
      join: comm_sub in CommissionSubscription,
      join: studio_sub in StudioSubscription,
      left_join: settings in assoc(u, :notification_settings),
      where:
        ((comm_sub.commission_id == ^commission.id and u.id == comm_sub.user_id) or
           (studio_sub.studio_id == ^commission.studio_id and u.id == studio_sub.user_id)) and
          (comm_sub.silenced != true or
             (studio_sub.studio_id != ^commission.studio_id and u.id != studio_sub.user_id and
                studio_sub.silenced != true)),
      distinct: u.id,
      select: %User{
        id: u.id,
        handle: u.handle,
        email: u.email,
        notification_settings: settings
      }
    )
    |> Repo.stream()
  end

  def new_commission(%Commission{} = commission, actor \\ nil) do
    Notifications.with_task(fn ->
      Phoenix.PubSub.broadcast!(
        @pubsub,
        "commission",
        %Phoenix.Socket.Broadcast{
          topic: "commission",
          event: "new_commission",
          payload: commission
        }
      )

      {:ok, _} =
        Repo.transaction(fn ->
          subs = Studios.Notifications.subscribers(%Studio{id: commission.studio_id})

          url = Routes.commission_url(Endpoint, :show, commission.public_id)
          {:safe, safe_url} = Phoenix.HTML.html_escape(url)

          Notifications.notify_subscribers!(
            actor,
            subs,
            %Notifications.UserNotification{
              type: "new_commission",
              title: commission.title,
              short_body: "A new commission has been submitted to your studio.",
              text_body: "A new commission has been submitted to your studio.\n\n#{url}",
              html_body:
                "<p>A new commission has been submitted to your studio.</p><p><a href=\"#{safe_url}\">View it</a></p>",
              url: url,
              read: false
            }
          )
        end)
    end)
  end

  def commission_event_updated(comm, ev, _actor \\ nil)

  def commission_event_updated(%Commission{} = commission, %Event{} = event, _actor) do
    Notifications.with_task(fn ->
      Phoenix.PubSub.broadcast!(
        @pubsub,
        "commission:#{commission.public_id}",
        %Phoenix.Socket.Broadcast{
          topic: "commission:#{commission.public_id}",
          event: "event_updated",
          payload: event
        }
      )

      # NOTE: No notifications in this case. event_updated is for things like
      # edits, that we don't want to spam users with.
    end)
  end

  def commission_event_updated(commission_id, event_id, _actor)
      when is_number(commission_id) and is_number(event_id) do
    commission_event_updated(
      %Commission{public_id: Commissions.get_public_id!(commission_id)},
      Repo.get!(Event, event_id)
      |> Repo.preload(attachments: [:upload, :preview, :thumbnail], invoice: [])
    )
  end

  def new_commission_events(%Commission{} = commission, events, actor \\ nil) do
    Notifications.with_task(fn ->
      Phoenix.PubSub.broadcast!(
        @pubsub,
        "commission:#{commission.public_id}",
        %Phoenix.Socket.Broadcast{
          topic: "commission:#{commission.public_id}",
          event: "new_events",
          payload: events
        }
      )

      {:ok, _} =
        Repo.transaction(fn ->
          subs = subscribers(commission)

          Enum.each(events, fn event ->
            url =
              Routes.commission_url(Endpoint, :show, commission.public_id)
              |> replace_fragment(event)

            body = new_event_notification_body(event)
            {:safe, safe_body} = Phoenix.HTML.html_escape(body)
            {:safe, safe_url} = Phoenix.HTML.html_escape(url)

            Notifications.notify_subscribers!(
              actor,
              subs,
              %Notifications.UserNotification{
                type: "new_event",
                title: commission.title,
                short_body: body,
                text_body: "#{body}\n\n#{url}",
                html_body: "<p>#{safe_body}</p><p><a href=\"#{safe_url}\">View it</a></p>",
                url: url,
                read: false
              },
              is_reply: true
            )
          end)
        end)
    end)
  end

  defp new_event_notification_body(%Event{
         type: :comment,
         actor: actor,
         actor_id: actor_id,
         text: body
       }) do
    %User{handle: handle} =
      if Ecto.assoc_loaded?(actor) do
        actor
      else
        Repo.get!(User, actor_id)
      end

    "#{handle} replied:\n\n#{body}"
  end

  defp new_event_notification_body(%Event{type: :line_item_added, amount: amount, text: text}) do
    "A new line item has been added to this commission:\n\n#{text}: #{Money.to_string(amount)}"
  end

  defp new_event_notification_body(%Event{type: :line_item_removed, amount: amount, text: text}) do
    "A line item has been removed from this commission:\n\n#{text}: #{Money.to_string(amount)}"
  end

  defp new_event_notification_body(%Event{type: :payment_processed, amount: amount}) do
    "A payment for #{Money.to_string(amount)} (including tips) has been successfully processed. It will be available for payout when the commission is completed and accepted."
  end

  defp new_event_notification_body(%Event{type: :refund_processed, amount: amount}) do
    "A refund for #{Money.to_string(amount)} has been issued successfully. Funds should clear in 5-10 days."
  end

  defp new_event_notification_body(%Event{type: :status, status: status}) do
    "The commission status has been changed to #{Common.humanize_status(status)}."
  end

  def commission_title_changed(%Commission{} = commission, _actor \\ nil) do
    Notifications.with_task(fn ->
      Phoenix.PubSub.broadcast!(
        @pubsub,
        "commission:#{commission.public_id}",
        %Phoenix.Socket.Broadcast{
          topic: "commission:#{commission.public_id}",
          event: "new_title",
          payload: commission.title
        }
      )
    end)
  end

  def commission_status_changed(%Commission{} = commission, _actor \\ nil) do
    Notifications.with_task(fn ->
      Phoenix.PubSub.broadcast!(
        @pubsub,
        "commission:#{commission.public_id}",
        %Phoenix.Socket.Broadcast{
          topic: "commission:#{commission.public_id}",
          event: "new_status",
          payload: commission.status
        }
      )

      # NOTE: No notifications in this case. event_updated is for things like
      # edits, that we don't want to spam users with.
    end)
  end

  def commission_line_items_changed(%Commission{} = commission, _actor \\ nil) do
    Notifications.with_task(fn ->
      Phoenix.PubSub.broadcast!(
        @pubsub,
        "commission:#{commission.public_id}",
        %Phoenix.Socket.Broadcast{
          topic: "commission:#{commission.public_id}",
          event: "line_items_changed",
          payload: commission.line_items
        }
      )

      # NOTE: No notification here because new_events takes care of notifying
      # about this already.
    end)
  end

  def invoice_released(%Commission{} = commission, %Event{} = event, actor \\ nil) do
    # No need for a broadcast. That's already being handled by commission_event_updated
    Notifications.with_task(fn ->
      {:ok, _} =
        Repo.transaction(fn ->
          subs = subscribers(commission)

          url =
            Routes.commission_url(Endpoint, :show, commission.public_id)
            |> replace_fragment(event)

          body = "An invoice has been released before commission approval."
          {:safe, safe_url} = Phoenix.HTML.html_escape(url)

          Notifications.notify_subscribers!(
            actor,
            subs,
            %Notifications.UserNotification{
              type: "invoice_released",
              title: commission.title,
              short_body: body,
              text_body: "#{body}\n\n#{url}",
              html_body: "<p>#{body}</p><p><a href=\"#{safe_url}\">View it</a></p>",
              url: url,
              read: false
            },
            is_reply: true
          )
        end)
    end)
  end

  def invoice_refund_updated(%Commission{} = commission, %Event{} = event, actor \\ nil) do
    # No need for a broadcast. That's already being handled by commission_event_updated
    Notifications.with_task(fn ->
      {:ok, _} =
        Repo.transaction(fn ->
          subs = subscribers(commission)

          url =
            Routes.commission_url(Endpoint, :show, commission.public_id)
            |> replace_fragment(event)

          body = refund_updated_body(event.invoice.refund_status)
          {:safe, safe_url} = Phoenix.HTML.html_escape(url)

          Notifications.notify_subscribers!(
            actor,
            subs,
            %Notifications.UserNotification{
              type: "invoice_refunded",
              title: commission.title,
              short_body: body,
              text_body: "#{body}\n\n#{url}",
              html_body: "<p>#{body}</p><p><a href=\"#{safe_url}\">View it</a></p>",
              url: url,
              read: false
            },
            is_reply: true
          )
        end)
    end)
  end

  defp refund_updated_body(refund_status)

  defp refund_updated_body(:pending) do
    "A refund has been submitted and is currently pending."
  end

  defp refund_updated_body(:succeeded) do
    raise "This event should be getting handled by new_commission_event instead."
  end

  defp refund_updated_body(:failed) do
    "A refund attempt has failed."
  end

  defp refund_updated_body(:canceled) do
    "A refund has been canceled."
  end

  defp refund_updated_body(:requires_action) do
    "A refund requires further action."
  end

  @doc """
  Emails an invoice receipt.
  """
  def send_receipt(%Invoice{} = invoice, %User{} = client, %Commission{} = commission) do
    Mailer.new_email(
      client.email,
      "Banchan Art Receipt for #{commission.title}",
      BanchanWeb.Email.CommissionsView,
      :receipt,
      invoice: invoice |> Repo.preload([:event]),
      commission: commission |> Repo.preload([:line_items]),
      deposited: Commissions.deposited_amount(client, commission, true),
      tipped: Commissions.tipped_amount(client, commission, true)
    )
    |> Mailer.deliver()
  end

  defp replace_fragment(uri, event) do
    URI.to_string(%{URI.parse(uri) | fragment: "event-#{event.public_id}"})
  end
end
