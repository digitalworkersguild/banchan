defmodule Banchan.Notifications do
  @moduledoc """
  Context module for notification-related operations.
  """
  import Ecto.Query, warn: false

  alias Banchan.Accounts.User
  alias Banchan.Workers.Mailer

  alias Banchan.Notifications.{
    UserNotification,
    UserNotificationSettings
  }

  alias Banchan.Repo

  @pubsub Banchan.PubSub

  # Whether to notify the actor themself of actions they take.
  # This is mostly intended to be used for testing the notification
  # system during development.
  @notify_actor false

  @doc """
  Marks all web notifications for this user as read, removing them from the
  web interface.
  """
  def mark_all_as_read(%User{} = user) do
    from(notification in UserNotification,
      where: notification.user_id == ^user.id
    )
    |> Repo.update_all(set: [read: true])

    Phoenix.PubSub.broadcast!(
      @pubsub,
      "notification:#{user.handle}",
      %Phoenix.Socket.Broadcast{
        topic: "notification:#{user.handle}",
        event: "all_notifications_read",
        payload: nil
      }
    )
  end

  @doc """
  Marks one specific notification as read, removing it from the web interface.
  """
  def mark_notification_read(%User{} = user, notification_ref) do
    from(notification in UserNotification,
      where: notification.user_id == ^user.id and notification.ref == ^notification_ref
    )
    |> Repo.update_all(set: [read: true])

    Phoenix.PubSub.broadcast!(
      @pubsub,
      "notification:#{user.handle}",
      %Phoenix.Socket.Broadcast{
        topic: "notification:#{user.handle}",
        event: "notification_read",
        payload: notification_ref
      }
    )
  end

  @doc """
  Gets UserNotificationSettings for a user, if any. Can return nil.
  """
  def get_notification_settings(%User{} = user) do
    Repo.one(from(settings in UserNotificationSettings, where: settings.user_id == ^user.id))
  end

  @doc """
  Updates a user's notification settings.
  """
  def update_user_notification_settings(%User{id: user_id}, attrs) do
    %UserNotificationSettings{
      user_id: user_id
    }
    |> UserNotificationSettings.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:user_id]
    )
  end

  @doc """
  Lists unread notifications for a user. Returns paginated results.
  """
  def unread_notifications(%User{} = user, page \\ 1) do
    from(
      n in UserNotification,
      where: n.user_id == ^user.id and n.read == false,
      order_by: {:desc, n.updated_at}
    )
    |> Repo.paginate(page: page, page_size: 20)
  end

  @doc """
  Subscribes the current process to notification broadcasts for a user.
  """
  def subscribe_to_notifications(%User{} = user) do
    Phoenix.PubSub.subscribe(@pubsub, "notification:#{user.handle}")
  end

  @doc """
  Unsubscribes the current process from notification broadcasts for a user.
  """
  def unsubscribe_from_notifications(%User{} = user) do
    Phoenix.PubSub.unsubscribe(@pubsub, "notification:#{user.handle}")
  end

  @doc """
  Waits for all active notification message tasks to process. Used for testing.
  """
  def wait_for_notifications do
    Task.Supervisor.children(Banchan.NotificationTaskSupervisor)
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      receive do
        # Order doesn't matter
        {:DOWN, ^ref, _, _, _} ->
          nil
      end
    end)
  end

  @doc """
  Utility function for spawning a task into the Banchan.NotificationTaskSupervisor.
  """
  def with_task(task) do
    Task.Supervisor.start_child(Banchan.NotificationTaskSupervisor, task)
  end

  @doc """
  Broadcasts a UserNotification to a list of given users. Whether the
  notification is sent to a particular user depends on their
  UserNotificationSettings, and whether the user is the same as `actor`.

  ## Notes

  For development, the `@notify_actor` setting in this module can be used to
  notifications, although they still won't be sent depending on the user's
  notification settings (and whether they have an email configured)
  """
  def notify_subscribers!(actor, subs, %UserNotification{} = notification, opts \\ []) do
    Enum.each(subs, fn %User{} = user ->
      if !actor || (actor && actor.id != user.id) || @notify_actor do
        send_web(user, notification)
        send_email(user, notification, opts)
      end
    end)
  end

  defp send_web(%User{} = user, %UserNotification{} = notification) do
    if is_nil(user.notification_settings) || user.notification_settings.commission_web do
      notification = Repo.insert!(%{notification | user_id: user.id}, returning: [:ref])

      Phoenix.PubSub.broadcast!(
        @pubsub,
        "notification:#{user.handle}",
        %Phoenix.Socket.Broadcast{
          topic: "notification:#{user.handle}",
          event: "new_notification",
          payload: notification
        }
      )
    end
  end

  defp send_email(%User{} = user, %UserNotification{} = notification, opts) do
    if (is_nil(user.notification_settings) || user.notification_settings.commission_email) &&
         user.email do
      title =
        if Keyword.get(opts, :is_reply, false) do
          "Re: " <> notification.title
        else
          notification.title
        end

      Mailer.deliver(%{
        to: user.email,
        subject: title,
        html_body: notification.html_body,
        text_body: notification.text_body
      })
    end
  end
end
