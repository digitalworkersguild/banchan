defmodule Banchan.Commissions do
  @moduledoc """
  The Commissions context.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Banchan.Repo

  alias Banchan.Commissions.{
    CommentHistory,
    Commission,
    CommissionArchived,
    CommissionFilter,
    Common,
    Event,
    EventAttachment,
    Invoice,
    LineItem,
    Notifications
  }

  alias Banchan.Accounts.User
  alias Banchan.Offerings
  alias Banchan.Offerings.{Offering, OfferingOption}
  alias Banchan.Studios
  alias Banchan.Studios.Studio
  alias Banchan.Uploads
  alias Banchan.Workers.Thumbnailer

  @pubsub Banchan.PubSub

  def list_commission_data_for_dashboard(
        %User{} = user,
        %CommissionFilter{} = filter,
        opts \\ []
      ) do
    main_dashboard_query(user)
    |> dashboard_query_filter(filter)
    |> dashboard_order_by(opts)
    |> Repo.paginate(
      page_size: Keyword.get(opts, :page_size, 24),
      page: Keyword.get(opts, :page, 1)
    )
  end

  defp main_dashboard_query(%User{} = user) do
    from s in Studio,
      join: c in Commission,
      on: c.studio_id == s.id,
      as: :commission,
      join: artist in assoc(s, :artists),
      as: :artist,
      join: u in User,
      as: :current_user,
      on: u.id == ^user.id,
      left_join: a in CommissionArchived,
      on: a.commission_id == c.id and a.user_id == u.id,
      as: :archived,
      join: client in assoc(c, :client),
      as: :client,
      join: e in assoc(c, :events),
      as: :events,
      group_by: [c.id, s.id, client.id, client.handle, s.handle, s.name, a.archived],
      # order_by: {:desc, max(e.inserted_at)},
      select: %{
        commission: %Commission{
          id: c.id,
          title: c.title,
          status: c.status,
          public_id: c.public_id,
          inserted_at: c.inserted_at
        },
        client: %User{
          id: client.id,
          name: client.name,
          handle: client.handle,
          pfp_thumb_id: client.pfp_thumb_id
        },
        studio: %Studio{
          id: s.id,
          handle: s.handle,
          name: s.name
        },
        archived: coalesce(a.archived, false),
        updated_at: max(e.inserted_at)
      }
  end

  defmacro status_order(arg) do
    cases =
      Common.status_values()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {status, idx} ->
        # NB(zkat): I'm sorry for not using fragment(). I don't think I can.
        "WHEN '#{status}' THEN #{idx}"
      end)

    quote do
      fragment(unquote("CASE ? #{cases} ELSE NULL END"), unquote(arg))
    end
  end

  defp dashboard_order_by(q, opts) do
    case Keyword.fetch(opts, :order_by) do
      {:ok, :recently_updated} ->
        q
        |> order_by([events: e], {:desc, max(e.inserted_at)})

      {:ok, :oldest_updated} ->
        q
        |> order_by([events: e], {:asc, max(e.inserted_at)})

      {:ok, :status} ->
        q
        |> order_by([commission: comm], {:asc, status_order(comm.status)})

      :error ->
        q
        |> order_by([events: e], {:desc, max(e.inserted_at)})
    end
  end

  defp dashboard_query_filter(query, %CommissionFilter{} = filter) do
    query
    |> filter_search(filter)
    |> filter_client(filter)
    |> filter_studio(filter)
    |> filter_statuses(filter)
    |> filter_show_archived(filter)
    |> filter_admin_show_all(filter)
  end

  defp filter_search(query, %CommissionFilter{} = filter) do
    if is_nil(filter.search) || filter.search == "" do
      query
    else
      query
      |> where(
        [commission: c, events: e],
        fragment("? @@ websearch_to_tsquery('banchan_fts', ?)", c.search_vector, ^filter.search) or
          fragment("? @@ websearch_to_tsquery('banchan_fts', ?)", e.search_vector, ^filter.search)
      )
    end
  end

  defp filter_client(query, %CommissionFilter{} = filter) do
    if is_nil(filter.client) || filter.client == "" do
      query
    else
      query
      |> where(
        [client: client],
        fragment(
          "? @@ websearch_to_tsquery('banchan_fts', ?)",
          client.search_vector,
          ^filter.client
        )
      )
    end
  end

  defp filter_studio(query, %CommissionFilter{} = filter) do
    if is_nil(filter.studio) || filter.studio == "" do
      query
    else
      query
      |> where(
        [studio: s],
        fragment("? @@ websearch_to_tsquery('banchan_fts', ?)", s.search_vector, ^filter.studio)
      )
    end
  end

  defp filter_statuses(query, %CommissionFilter{} = filter) do
    if is_nil(filter.statuses) || Enum.empty?(filter.statuses) do
      query
    else
      query
      |> where([commission: c], c.status in ^filter.statuses)
    end
  end

  defp filter_show_archived(query, %CommissionFilter{} = filter) do
    if filter.show_archived do
      query
    else
      query
      |> where([archived: archived], not coalesce(archived.archived, false))
    end
  end

  defp filter_admin_show_all(query, %CommissionFilter{} = filter) do
    if filter.admin_show_all do
      query
      |> where(
        [
          commission: c,
          artist: artist,
          current_user: u
        ],
        :admin in u.roles or :mod in u.roles or c.client_id == u.id or artist.id == u.id
      )
    else
      query
      |> where(
        [commission: c, artist: artist, current_user: u],
        c.client_id == u.id or artist.id == u.id
      )
    end
  end

  @doc """
  Gets a single commission for a studio.

  Raises `Ecto.NoResultsError` if the Commission does not exist.
  """
  def get_commission!(public_id, current_user) do
    Repo.one!(
      from c in Commission,
        join: s in assoc(c, :studio),
        join: artist in assoc(s, :artists),
        join: u in User,
        on: u.id == ^current_user.id,
        where:
          c.public_id == ^public_id and
            (:admin in u.roles or
               :mod in u.roles or
               c.client_id == ^current_user.id or
               ^current_user.id == artist.id),
        preload: [
          :studio,
          events: [invoice: [], attachments: [:upload, :thumbnail, :preview]],
          line_items: [:option],
          offering: [:options, :studio]
        ]
    )
  end

  def get_public_id!(commission_id) do
    %{public_id: public_id} =
      Repo.one!(
        from c in Commission,
          where: c.id == ^commission_id,
          select: %{
            public_id: c.public_id
          }
      )

    public_id
  end

  # TODO: maybe this is too wide a net? We can separate this into user-level
  # and studio-level subscriptions, though it will mean multiple calls to
  # these subscription functions.
  def subscribe_to_new_commissions do
    Phoenix.PubSub.subscribe(@pubsub, "commission")
  end

  def unsubscribe_from_new_commissions do
    Phoenix.PubSub.unsubscribe(@pubsub, "commission")
  end

  def subscribe_to_commission_events(%Commission{public_id: public_id}) do
    Phoenix.PubSub.subscribe(@pubsub, "commission:#{public_id}")
  end

  def unsubscribe_from_commission_events(%Commission{public_id: public_id}) do
    Phoenix.PubSub.unsubscribe(@pubsub, "commission:#{public_id}")
  end

  @doc """
  Creates a commission.

  ## Examples

      iex> create_commission(actor, studio, offering, %{field: value})
      {:ok, %Commission{}}

      iex> create_commission(actor, studio, offering, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_commission(
        %User{} = actor,
        %Studio{} = studio,
        %Offering{} = offering,
        line_items,
        attachments,
        attrs \\ %{}
      ) do
    {:ok, ret} =
      Repo.transaction(fn ->
        if Studios.user_blocked?(studio, actor) do
          {:error, :blocked}
        else
          offering = offering |> Repo.reload()
          available_proposal_count = Offerings.offering_available_proposals(offering)

          maybe_close_offering(offering, available_proposal_count)

          cond do
            !is_nil(offering.archived_at) ->
              {:error, :offering_archived}

            !offering.open ->
              {:error, :offering_closed}

            is_nil(actor.confirmed_at) ->
              {:error, :not_confirmed}

            !is_nil(available_proposal_count) && available_proposal_count <= 0 ->
              {:error, :no_proposals_available}

            true ->
              insert_commission(actor, studio, offering, line_items, attachments, attrs)
          end
        end
      end)

    ret
  end

  defp maybe_close_offering(offering, available_proposal_count) do
    # Make sure we close the offering if we're out of proposals.
    close = !is_nil(available_proposal_count) && available_proposal_count <= 1

    if close do
      # NB(zkat): We pretend we're a studio member here because we're doing
      # this on behalf of the studio. It's safe.
      {:ok, _} = Offerings.update_offering(nil, offering, true, %{open: false}, nil)
    end
  end

  defp insert_commission(actor, studio, offering, line_items, attachments, attrs) do
    {:ok, ret} =
      Repo.transaction(fn ->
        comm_changeset =
          %Commission{
            studio: studio,
            offering: offering,
            client: actor,
            line_items: line_items
          }
          |> Commission.creation_changeset(attrs)

        with {:ok, %Commission{} = commission} <- Repo.insert(comm_changeset),
             _ <- Notifications.subscribe_user!(actor, commission),
             {:ok, _} <-
               create_event(
                 :comment,
                 actor,
                 commission,
                 true,
                 attachments,
                 %{
                   text: Map.get(attrs, "description", "")
                 },
                 false
               ) do
          commission =
            commission |> Repo.preload(events: [attachments: [:upload, :thumbnail, :preview]])

          Notifications.new_commission(commission, actor)
          {:ok, commission}
        end
      end)

    ret
  end

  def archived?(%User{} = user, %Commission{} = commission) do
    from(archived in CommissionArchived,
      where:
        archived.user_id == ^user.id and archived.commission_id == ^commission.id and
          archived.archived != false
    )
    |> Repo.exists?()
  end

  def update_archived(%User{} = actor, %Commission{} = commission, archived?) do
    %CommissionArchived{user: actor, commission: commission, archived: archived?}
    |> Repo.insert(
      on_conflict: {:replace, [:archived]},
      conflict_target: [:user_id, :commission_id]
    )
  end

  def update_title(%User{} = actor, %Commission{} = commission, attrs) do
    {:ok, ret} =
      Repo.transaction(fn ->
        if Studios.user_blocked?(%Studio{id: commission.studio_id}, actor) do
          {:error, :blocked}
        else
          old_title = Repo.reload(commission).title

          commission
          |> Commission.update_title_changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, commission} ->
              Notifications.commission_title_changed(commission, actor)

              with {:ok, _} <-
                     create_event(:title_changed, actor, commission, true, [], %{text: old_title}) do
                {:ok, commission}
              end

            {:error, err} ->
              {:error, err}
          end
        end
      end)

    ret
  end

  def update_status(%User{} = actor, %Commission{} = commission, status) do
    {:ok, ret} =
      Repo.transaction(fn ->
        if Studios.user_blocked?(%Studio{id: commission.studio_id}, actor) do
          {:error, :blocked}
        else
          changeset = Repo.reload!(commission) |> Commission.status_changeset(%{status: status})

          check_status_transition!(actor, commission, changeset.changes.status)

          {:ok, commission} = changeset |> Repo.update()

          if commission.status == :accepted do
            offering = Repo.preload(commission, :offering).offering
            available_slot_count = Offerings.offering_available_slots(offering, true)

            # Make sure we close the offering if we're out of slots.
            close = !is_nil(available_slot_count) && available_slot_count <= 1

            if close do
              # NB(zkat): We pretend we're a studio member here because we're doing
              # this on behalf of the studio. It's safe.
              {:ok, _} = Offerings.update_offering(nil, offering, true, %{open: false}, nil)
            end
          end

          if commission.status == :approved do
            # Release any successful deposits.
            from(i in Invoice,
              where: i.commission_id == ^commission.id and i.status == :succeeded
            )
            |> Repo.update_all(set: [status: :released])

            from(e in Event,
              join: i in assoc(e, :invoice),
              where: i.commission_id == ^commission.id and i.status == :released,
              select: e,
              preload: [:actor, invoice: [], attachments: [:upload, :thumbnail, :preview]]
            )
            |> Repo.all()
            |> Enum.each(fn ev ->
              Notifications.commission_event_updated(commission, ev, actor)
            end)
          end

          # current_user_member? is checked as part of check_status_transition!
          with {:ok, event} <-
                 create_event(:status, actor, commission, true, [], %{status: status}) do
            Notifications.commission_status_changed(commission, actor)

            {:ok, {commission, [event]}}
          end
        end
      end)

    ret
  end

  def release_payment!(%User{} = actor, %Commission{} = commission, %Invoice{} = invoice) do
    {:ok, ret} =
      Repo.transaction(fn ->
        if Studios.user_blocked?(%Studio{id: commission.studio_id}, actor) do
          # TODO: Make release_payment be a regular function instead of raising, and return {:error, :blocked} here.
          raise "user blocked"
        else
          {1, _} =
            from(i in Invoice,
              join: c in assoc(i, :commission),
              where: i.id == ^invoice.id and c.client_id == ^actor.id and i.status == :succeeded
            )
            |> Repo.update_all(set: [status: :released])

          ev =
            from(e in Event,
              where: e.id == ^invoice.event_id,
              select: e,
              preload: [:actor, invoice: [], attachments: [:upload, :thumbnail, :preview]]
            )
            |> Repo.one!()

          Notifications.invoice_released(commission, ev, actor)
          Notifications.commission_event_updated(commission, ev, actor)

          :ok
        end
      end)

    ret
  end

  defp check_status_transition!(
         %User{} = actor,
         %Commission{client_id: client_id, studio_id: studio_id, status: current_status},
         new_status
       ) do
    {:ok, _} =
      Repo.transaction(fn ->
        actor_member? = Studios.is_user_in_studio?(actor, %Studio{id: studio_id})

        true =
          status_transition_allowed?(
            actor_member? || :admin in actor.roles || :mod in actor.roles,
            client_id == actor.id || :admin in actor.roles || :mod in actor.roles,
            current_status,
            new_status
          )
      end)

    :ok
  end

  # Transition changes studios can make
  defp status_transition_allowed?(artist?, client?, from, to)

  defp status_transition_allowed?(true, _, :submitted, :accepted), do: true
  defp status_transition_allowed?(true, _, :submitted, :rejected), do: true
  defp status_transition_allowed?(true, _, :accepted, :in_progress), do: true
  defp status_transition_allowed?(true, _, :accepted, :ready_for_review), do: true
  defp status_transition_allowed?(true, _, :in_progress, :paused), do: true
  defp status_transition_allowed?(true, _, :in_progress, :waiting), do: true
  defp status_transition_allowed?(true, _, :in_progress, :ready_for_review), do: true
  defp status_transition_allowed?(true, _, :paused, :in_progress), do: true
  defp status_transition_allowed?(true, _, :waiting, :in_progress), do: true
  defp status_transition_allowed?(true, _, :ready_for_review, :in_progress), do: true
  defp status_transition_allowed?(true, _, :approved, :accepted), do: true
  defp status_transition_allowed?(true, _, :withdrawn, :accepted), do: true
  defp status_transition_allowed?(true, _, :rejected, :accepted), do: true

  # Transition changes clients can make
  defp status_transition_allowed?(_, true, :ready_for_review, :approved), do: true
  defp status_transition_allowed?(_, true, :withdrawn, :submitted), do: true

  # Either party can withdraw a commission (reimbursing the client)
  defp status_transition_allowed?(_, _, _, :withdrawn), do: true

  # Everything else is a no from me, Bob.
  defp status_transition_allowed?(_, _, _, _), do: false

  def commission_open?(%Commission{status: :withdrawn}), do: false
  def commission_open?(%Commission{status: :rejected}), do: false
  def commission_open?(%Commission{status: :approved}), do: false
  def commission_open?(%Commission{}), do: true

  def add_line_item(_, _, _, false) do
    {:error, :not_studio_member}
  end

  def add_line_item(%User{} = actor, %Commission{} = commission, option, true) do
    case option do
      %OfferingOption{} ->
        %LineItem{
          commission_id: commission.id,
          option: option,
          amount: option.price,
          name: option.name,
          description: option.description
        }

      %{amount: amount, name: name, description: description} ->
        %LineItem{
          commission_id: commission.id,
          amount: amount,
          name: name,
          description: description
        }
    end
    |> Repo.insert()
    |> case do
      {:error, err} ->
        {:error, err}

      {:ok, line_item} ->
        line_item = line_item |> Repo.preload(:option)
        line_items = commission.line_items ++ [line_item]
        commission = %{commission | line_items: line_items}
        {:ok, {line_item, commission}}
    end
    |> case do
      {:error, err} ->
        {:error, err}

      {:ok, {line_item, commission}} ->
        case create_event(:line_item_added, actor, commission, true, [], %{
               amount: line_item.amount,
               text: line_item.name
             }) do
          {:error, err} ->
            {:error, err}

          {:ok, event} ->
            Notifications.commission_line_items_changed(commission, actor)
            {:ok, {commission, [event]}}
        end
    end
  end

  def remove_line_item(_, _, _, false) do
    {:error, :not_studio_member}
  end

  def remove_line_item(%User{} = actor, %Commission{} = commission, line_item, true) do
    line_item
    |> Repo.delete()
    |> case do
      {:error, err} ->
        {:error, err}

      {:ok, _} ->
        line_items = Enum.filter(commission.line_items, &(&1.id != line_item.id))
        commission = %{commission | line_items: line_items}
        {:ok, {line_item, commission}}
    end
    |> case do
      {:error, err} ->
        {:error, err}

      {:ok, {line_item, commission}} ->
        case create_event(:line_item_removed, actor, commission, true, [], %{
               amount: line_item.amount,
               text: line_item.name
             }) do
          {:error, err} ->
            {:error, err}

          {:ok, event} ->
            Notifications.commission_line_items_changed(commission, actor)
            {:ok, {commission, [event]}}
        end
    end
  end

  @doc """
  Creates a event.
  """
  def create_event(
        type,
        actor,
        commission,
        current_user_member?,
        attachments,
        attrs,
        notify \\ true
      )

  def create_event(
        type,
        %User{id: user_id, roles: roles} = actor,
        %Commission{client_id: client_id} = comm,
        current_user_member?,
        attachments,
        attrs,
        notify
      )
      when user_id != client_id and current_user_member? == false do
    if :admin in roles || :mod in roles do
      create_event(type, actor, comm, true, attachments, attrs, notify)
    else
      {:error, :unauthorized}
    end
  end

  def create_event(
        type,
        %User{} = actor,
        %Commission{} = commission,
        _current_user_member?,
        attachments,
        attrs,
        notify
      )
      when is_atom(type) do
    {:ok, ret} =
      Repo.transaction(fn ->
        changeset =
          %Event{
            type: type,
            commission_id: commission.id,
            actor_id: actor.id
          }
          |> Event.changeset(attrs)

        with :ok <-
               (if Studios.user_blocked?(%Studio{id: commission.studio_id}, actor) do
                  {:error, :blocked}
                else
                  :ok
                end),
             {:ok, event} <- Repo.insert(changeset),
             :ok <- add_attachments(event, attachments) do
          event = event |> Repo.preload(attachments: [:upload, :thumbnail, :preview])

          if notify do
            Notifications.new_commission_events(commission, [%{event | invoice: nil}], actor)
          end

          {:ok, event}
        end || {:error, :event_failure}
      end)

    ret
  end

  @doc """
  Updates a event.

  ## Examples

      iex> update_event(event, %{field: new_value})
      {:ok, %Event{}}

      iex> update_event(event, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_event(%User{} = actor, %Event{} = event, attrs) do
    {:ok, ret} =
      Repo.transaction(fn ->
        event = Repo.get!(Event, event.id) |> Repo.preload(:commission)

        if Studios.user_blocked?(%Studio{id: event.commission.studio_id}, actor) do
          {:error, :blocked}
        else
          original_text = event.text
          changeset = Event.changeset(event, attrs)

          changeset
          |> Repo.update()
          |> case do
            {:ok, event} ->
              if Ecto.Changeset.fetch_change(changeset, :text) == :error do
                {:ok, event}
              else
                %CommentHistory{
                  text: original_text,
                  written_at: event.updated_at,
                  event_id: event.id,
                  changed_by_id: actor.id
                }
                |> Repo.insert()
                |> case do
                  {:ok, _} ->
                    {:ok, event}

                  {:error, err} ->
                    {:error, err}
                end
              end

            {:error, err} ->
              {:error, err}
          end
        end
      end)

    ret
  end

  @doc """
  Deletes a event.

  ## Examples

      iex> delete_event(event)
      {:ok, %Event{}}

      iex> delete_event(event)
      {:error, %Ecto.Changeset{}}

  """
  def delete_event(%Event{} = event) do
    Repo.delete(event)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking event changes.

  ## Examples

      iex> change_event(event)
      %Ecto.Changeset{data: %Event{}}

  """
  def change_event(%Event{} = event, attrs \\ %{}) do
    Event.changeset(event, attrs)
  end

  def change_event_text(%Event{} = event, attrs \\ %{}) do
    Event.text_changeset(event, attrs)
  end

  def send_event_update!(event_id, actor \\ nil) do
    event =
      from(e in Event,
        where: e.id == ^event_id,
        select: e,
        preload: [:actor, invoice: [], attachments: [:upload, :thumbnail, :preview]]
      )
      |> Repo.one!()

    commission =
      from(c in Commission, where: c.id == ^event.commission_id)
      |> Repo.one!()

    Notifications.commission_event_updated(commission, event, actor)
  end

  # This one expects binaries for everything because it looks everything up in one fell swoop.
  def get_attachment_if_allowed!(commission, key, user) do
    Repo.one!(
      from ea in EventAttachment,
        join: ul in assoc(ea, :upload),
        join: e in assoc(ea, :event),
        join: c in assoc(e, :commission),
        join: s in assoc(c, :studio),
        join: artist in assoc(s, :artists),
        left_join: i in assoc(e, :invoice),
        select: ea,
        # Either the user is a studio member
        # Or the user is the client
        # And the invoice requires payment to view attachments and has succeeded
        # Or the invoice doesn't require payment to view attachments
        where:
          c.public_id == ^commission and
            ul.key == ^key and
            (artist.id == ^user.id or
               (c.client_id == ^user.id and
                  ((i.required and i.status == :succeeded) or not i.required or is_nil(i.required)))),
        preload: [:upload, :thumbnail, :preview]
    )
  end

  def add_attachments(%Event{} = event, attachments) do
    {:ok, _} =
      Repo.transaction(fn ->
        Enum.each(attachments, fn upload ->
          {:ok, thumbnail} =
            if Uploads.image?(upload) || Uploads.video?(upload) do
              Thumbnailer.thumbnail(
                upload,
                target_size: "5kb",
                dimensions: "128x128",
                callback: [
                  Notifications,
                  :commission_event_updated,
                  [event.commission_id, event.id]
                ]
              )
            else
              {:ok, nil}
            end

          {:ok, preview} =
            if Uploads.image?(upload) || Uploads.video?(upload) do
              Thumbnailer.thumbnail(
                upload,
                dimensions: "1200",
                name: "preview.jpg",
                callback: [
                  Notifications,
                  :commission_event_updated,
                  [event.commission_id, event.id]
                ]
              )
            else
              {:ok, nil}
            end

          %EventAttachment{
            event: event,
            upload: upload,
            thumbnail: thumbnail,
            preview: preview
          }
          |> Repo.insert!()
        end)
      end)

    :ok
  end

  def delete_attachment!(
        %User{} = actor,
        %Commission{} = commission,
        %Event{} = event,
        %EventAttachment{} = event_attachment
      ) do
    # NOTE: This also deletes any associated uploads, because of the db ON DELETE
    Repo.delete!(event_attachment)
    new_attachments = Enum.reject(event.attachments, &(&1.id == event_attachment.id))

    Notifications.commission_event_updated(
      commission,
      %{event | attachments: new_attachments},
      actor
    )
  end

  def add_comment(
        %User{} = actor,
        %Commission{} = commission,
        current_user_member?,
        attachments,
        text
      ) do
    create_event(
      :comment,
      actor,
      commission,
      current_user_member?,
      attachments,
      %{"text" => text}
    )
  end

  def invoice_paid?(%Invoice{status: status}), do: status == :succeeded

  def invoice(%User{roles: roles} = actor, comm, false, drafts, event_data) do
    if :admin in roles or :client in roles do
      invoice(actor, comm, true, drafts, event_data)
    else
      {:error, :unauthorized}
    end
  end

  def invoice(%User{} = actor, %Commission{} = commission, true, drafts, event_data) do
    {:ok, ret} =
      Repo.transaction(fn ->
        case create_event(:comment, actor, commission, true, drafts, event_data) do
          {:error, error} ->
            {:error, error}

          {:ok, event} ->
            case %Invoice{
                   client_id: commission.client_id,
                   commission: commission,
                   event: event
                 }
                 |> Invoice.creation_changeset(event_data)
                 |> Repo.insert() do
              {:error, error} ->
                {:error, error}

              {:ok, invoice} ->
                send_event_update!(event.id, actor)
                {:ok, invoice}
            end
        end
      end)

    ret
  end

  def process_payment!(%User{id: user_id}, _, %Commission{client_id: client_id}, _, _)
      when user_id != client_id do
    {:error, :unauthorized}
  end

  def process_payment!(
        %User{} = actor,
        %Event{invoice: %Invoice{amount: amount} = invoice} = event,
        %Commission{} = commission,
        uri,
        tip
      ) do
    items = [
      %{
        name: "Commission Invoice Payment",
        quantity: 1,
        amount: amount.amount,
        currency: String.downcase(to_string(amount.currency))
      },
      %{
        name: "Extra Tip",
        quantity: 1,
        amount: tip.amount,
        currency: String.downcase(to_string(tip.currency))
      }
    ]

    {stripe_id, platform_fee} =
      from(studio in Studio,
        where: studio.id == ^commission.studio_id,
        select: {studio.stripe_id, studio.platform_fee}
      )
      |> Repo.one!()

    platform_fee = Money.multiply(Money.add(amount, tip), platform_fee)
    transfer_amt = amount |> Money.add(tip) |> Money.subtract(platform_fee)

    {:ok, session} =
      stripe_mod().create_session(%{
        payment_method_types: ["card"],
        mode: "payment",
        cancel_url: uri,
        success_url: uri,
        line_items: items,
        payment_intent_data: %{
          transfer_data: %{
            amount: transfer_amt.amount,
            destination: stripe_id
          }
        }
      })

    invoice
    |> Invoice.submit_changeset(%{
      tip: tip,
      platform_fee: platform_fee,
      stripe_session_id: session.id,
      checkout_url: session.url,
      status: :submitted
    })
    |> Repo.update!()

    send_event_update!(event.id, actor)

    session.url
  end

  def process_payment_succeeded!(session) do
    {:ok, %{charges: %{data: [%{balance_transaction: txn_id, transfer: transfer}]}}} =
      stripe_mod().retrieve_payment_intent(session.payment_intent, %{}, [])

    {:ok, %{available_on: available_on, amount: amt, currency: curr}} =
      stripe_mod().retrieve_balance_transaction(txn_id, [])

    {:ok, transfer} = stripe_mod().retrieve_transfer(transfer)

    total_charged = Money.new(amt, String.to_atom(String.upcase(curr)))
    final_transfer_txn = transfer.destination_payment.balance_transaction

    total_transferred =
      Money.new(
        final_transfer_txn.amount,
        String.to_atom(String.upcase(final_transfer_txn.currency))
      )

    {:ok, available_on} = DateTime.from_unix(available_on)

    {:ok, _} =
      Repo.transaction(fn ->
        {1, [invoice]} =
          from(i in Invoice, where: i.stripe_session_id == ^session.id, select: i)
          |> Repo.update_all(
            set: [
              status: :succeeded,
              payout_available_on: available_on,
              total_charged: total_charged,
              total_transferred: total_transferred
            ]
          )

        event = Repo.get!(Event, invoice.event_id)
        client = Repo.reload!(%User{id: invoice.client_id})
        commission = Repo.reload!(%Commission{id: event.commission_id})

        create_event(
          :payment_processed,
          client,
          commission,
          true,
          [],
          %{
            amount: invoice.amount |> Money.add(invoice.tip)
          }
        )

        if client.email do
          Notifications.send_receipt(invoice, client, commission)
        end

        send_event_update!(invoice.event_id)
      end)

    :ok
  end

  def process_payment_expired!(session) do
    # NOTE: This will crash (intentionally) if we try to expire an
    # already-succeeded payment. This should never happen, though, because it
    # doesn't make sense that Stripe would tell us that a payment succeeded
    # then tell us it's expired. So this crash is a good just-in-case.
    {1, [invoice]} =
      from(i in Invoice,
        where: i.stripe_session_id == ^session.id and i.status != :succeeded,
        select: i
      )
      |> Repo.update_all(set: [status: :expired])

    send_event_update!(invoice.event_id)
  end

  def expire_payment!(invoice, current_user_member?)

  def expire_payment!(_, false) do
    {:error, :unauthorized}
  end

  def expire_payment!(%Invoice{id: id, stripe_session_id: nil, status: :pending}, _) do
    # NOTE: This will crash (intentionally) if we try to expire an already-succeeded payment.
    {1, [invoice]} =
      from(i in Invoice, where: i.id == ^id and i.status != :succeeded, select: i)
      |> Repo.update_all(set: [status: :expired])

    send_event_update!(invoice.event_id)
    :ok
  end

  def expire_payment!(%Invoice{stripe_session_id: session_id, status: :submitted}, _)
      when session_id != nil do
    # NOTE: We don't manually expire the invoice in the database here. That's
    # handled by process_payment_expired!/1 when the webhook fires.
    case stripe_mod().expire_payment(session_id) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        raise error.message
    end
  end

  def expire_payment!(%Invoice{}, _) do
    raise "Tried to expire an invoice in an invalid state. Reload the invoice and try again. Otherwise, this is a bug."
  end

  def refund_payment(actor, invoice, current_user_member?)

  def refund_payment(_, _, false) do
    {:error, :unauthorized}
  end

  def refund_payment(%User{} = actor, %Invoice{} = invoice, _) do
    {:ok, ret} =
      Repo.transaction(fn ->
        invoice = invoice |> Repo.reload()

        if invoice.status != :succeeded do
          Logger.error(%{
            message: "Attempted to refund an invoice that wasn't :succeeded.",
            invoice: invoice
          })

          {:error, :invoice_not_refundable}
        else
          process_refund_payment(actor, invoice)
        end
      end)

    ret
  end

  defp process_refund_payment(%User{} = actor, %Invoice{} = invoice) do
    case refund_payment_on_stripe(invoice) do
      {:ok, %Stripe.Refund{status: "failed"} = refund} ->
        Logger.error(%{message: "Refund failed", refund: refund})
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "canceled"} = refund} ->
        Logger.error(%{message: "Refund canceled", refund: refund})
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "requires_action"} = refund} ->
        Logger.info(%{message: "Refund requires action", refund: refund})
        # This should eventually succeed asynchronously.
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "succeeded"} = refund} ->
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "pending"} = refund} ->
        process_refund_updated(refund, invoice.id, actor)

      {:error, %Stripe.Error{} = err} ->
        {:error, err}
    end
  end

  defp refund_payment_on_stripe(%Invoice{} = invoice) do
    case stripe_mod().retrieve_session(invoice.stripe_session_id, []) do
      {:ok, session} ->
        case stripe_mod().retrieve_payment_intent(session.payment_intent, %{}, []) do
          {:ok, %Stripe.PaymentIntent{charges: %{data: [%{id: charge_id}]}}} ->
            # https://stripe.com/docs/connect/destination-charges#issuing-refunds
            case stripe_mod().create_refund(
                   %{
                     charge: charge_id,
                     reverse_transfer: true,
                     refund_application_fee: true
                   },
                   []
                 ) do
              {:ok, refund} ->
                {:ok, refund}

              {:error, err} ->
                Logger.error(%{message: "Refund failed.", error: err})
                {:error, err}
            end

          {:error, err} ->
            Logger.error(%{
              message: "Failed to retrieve payment intent while refunding.",
              error: err
            })

            {:error, err}
        end

      {:error, err} ->
        Logger.error(%{message: "Failed to retrieve session while refunding.", error: err})
        {:error, err}
    end
  end

  # Disabling because honestly, refactoring this one is pointless.
  #
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def process_refund_updated(%Stripe.Refund{} = refund, invoice_id, actor \\ nil) do
    {:ok, ret} =
      Repo.transaction(fn ->
        assignments =
          case refund.status do
            "succeeded" ->
              [
                status: :refunded,
                refund_status: :succeeded,
                stripe_refund_id: refund.id,
                refund_failure_reason: nil
              ]

            "failed" ->
              [
                refund_status: :failed,
                stripe_refund_id: refund.id,
                refund_failure_reason: refund.failure_reason
              ]

            "canceled" ->
              [refund_status: :canceled, stripe_refund_id: refund.id, refund_failure_reason: nil]

            "pending" ->
              [refund_status: :pending, stripe_refund_id: refund.id, refund_failure_reason: nil]

            "requires_action" ->
              [
                refund_status: :requires_action,
                stripe_refund_id: refund.id,
                refund_failure_reason: nil
              ]
          end

        assignments =
          if is_nil(actor) do
            assignments
          else
            assignments ++ [refunded_by_id: actor.id]
          end

        update_res =
          if is_nil(invoice_id) do
            from(i in Invoice,
              where: i.status == :succeeded and i.stripe_refund_id == ^refund.id,
              select: i.id
            )
          else
            from(i in Invoice, where: i.status == :succeeded and i.id == ^invoice_id, select: i.id)
          end
          |> Repo.update_all(set: assignments)

        case update_res do
          {1, [invoice_id]} ->
            case from(e in Event,
                   join: i in assoc(e, :invoice),
                   where: i.id == ^invoice_id,
                   select: e,
                   preload: [
                     :actor,
                     :commission,
                     invoice: [],
                     attachments: [:upload, :thumbnail, :preview]
                   ]
                 )
                 |> Repo.one() do
              %Event{} = ev -> {:ok, ev}
              nil -> {:error, :event_not_found}
            end

          {0, _} ->
            {:error, :invoice_not_found}
        end
      end)

    case ret do
      {:ok, event} ->
        if event.invoice.refund_status == :succeeded do
          actor =
            cond do
              is_nil(actor) && event.invoice.refunded_by_id ->
                %User{id: event.invoice.refunded_by_id} |> Repo.reload!()

              !is_nil(actor) ->
                actor

              true ->
                raise "Bad state: an invoice was succeeded that didn't already have a refunded_by_id."
            end

          create_event(
            :refund_processed,
            actor,
            event.commission,
            true,
            [],
            %{
              amount: Money.new(refund.amount, String.to_atom(String.upcase(refund.currency)))
            }
          )
        else
          Notifications.invoice_refund_updated(event.commission, event, actor)
        end

        Notifications.commission_event_updated(event.commission, event, actor)
        {:ok, event.invoice}

      {:error, err} ->
        Logger.error(%{message: "Failed to update invoice status to refunded", error: err})
        {:error, :internal_error}
    end
  end

  def deposited_amount(
        %User{id: user_id, roles: roles} = actor,
        %Commission{client_id: client_id} = comm,
        current_user_member?
      )
      when user_id != client_id and current_user_member? == false do
    if :admin in roles || :mod in roles do
      deposited_amount(actor, comm, true)
    else
      {:error, :unauthorized}
    end
  end

  def deposited_amount(_, %Commission{} = commission, _) do
    if Ecto.assoc_loaded?(commission.events) do
      Enum.reduce(
        commission.events,
        %{},
        fn event, acc ->
          if event.invoice && event.invoice.status in [:succeeded, :released] do
            current =
              Map.get(
                acc,
                event.invoice.amount.currency,
                Money.new(0, event.invoice.amount.currency)
              )

            Map.put(acc, event.invoice.amount.currency, Money.add(current, event.invoice.amount))
          else
            acc
          end
        end
      )
    else
      deposits =
        from(
          i in Invoice,
          where:
            i.commission_id == ^commission.id and
              i.status == :succeeded,
          select: i.amount
        )
        |> Repo.all()

      Enum.reduce(
        deposits,
        %{},
        fn dep, acc ->
          current = Map.get(acc, dep.currency, Money.new(0, dep.currency))
          Map.put(acc, dep.currency, Money.add(current, dep))
        end
      )
    end
  end

  def tipped_amount(
        %User{id: user_id, roles: roles} = actor,
        %Commission{client_id: client_id} = comm,
        current_user_member?
      )
      when user_id != client_id and current_user_member? == false do
    if :admin in roles || :mod in roles do
      tipped_amount(actor, comm, true)
    else
      {:error, :unauthorized}
    end
  end

  def tipped_amount(_, %Commission{} = commission, _) do
    if Ecto.assoc_loaded?(commission.events) do
      Enum.reduce(
        commission.events,
        %{},
        fn event, acc ->
          if event.invoice && event.invoice.status in [:succeeded, :released] do
            current =
              Map.get(
                acc,
                event.invoice.tip.currency,
                Money.new(0, event.invoice.tip.currency)
              )

            Map.put(acc, event.invoice.tip.currency, Money.add(current, event.invoice.tip.amount))
          else
            acc
          end
        end
      )
    else
      deposits =
        from(
          i in Invoice,
          where:
            i.commission_id == ^commission.id and
              i.status == :succeeded,
          select: i.tip
        )
        |> Repo.all()

      Enum.reduce(
        deposits,
        %{},
        fn dep, acc ->
          current = Map.get(acc, dep.currency, Money.new(0, dep.currency))
          Map.put(acc, dep.currency, Money.add(current, dep))
        end
      )
    end
  end

  def line_item_estimate(line_items) do
    Enum.reduce(
      line_items,
      %{},
      fn item, acc ->
        current =
          Map.get(
            acc,
            item.amount.currency,
            Money.new(0, item.amount.currency)
          )

        Map.put(acc, item.amount.currency, Money.add(current, item.amount))
      end
    )
  end

  def list_attachments(%Commission{} = commission) do
    from(ea in EventAttachment,
      join: e in assoc(ea, :event),
      left_join: i in assoc(e, :invoice),
      where:
        e.commission_id == ^commission.id and
          (is_nil(i.required) or
             not i.required or (i.required and i.status == :succeeded)),
      order_by: [desc: e.inserted_at],
      preload: [:upload, :thumbnail, :preview]
    )
    |> Repo.all()
  end

  defp stripe_mod do
    Application.get_env(:banchan, :stripe_mod)
  end
end
