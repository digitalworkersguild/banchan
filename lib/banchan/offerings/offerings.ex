defmodule Banchan.Offerings do
  @moduledoc """
  Main context module for Offerings.
  """
  import Ecto.Query, warn: false

  alias Banchan.Accounts.User
  alias Banchan.Commissions.Commission

  alias Banchan.Offerings.{
    GalleryImage,
    Notifications,
    Offering,
    OfferingOption,
    OfferingSubscription
  }

  alias Banchan.Repo
  alias Banchan.Studios
  alias Banchan.Studios.Studio
  alias Banchan.Uploads
  alias Banchan.Uploads.Upload
  alias Banchan.Workers.Thumbnailer

  ## Creation

  @doc """
  Creates a new offering.
  """
  def new_offering(actor, %Studio{} = studio, false, attrs, gallery_images) do
    if is_nil(actor) || :admin in actor.roles || :mod in actor.roles do
      new_offering(actor, studio, true, attrs, gallery_images)
    else
      {:error, :unauthorized}
    end
  end

  def new_offering(actor, %Studio{} = studio, true, attrs, gallery_images) do
    {:ok, ret} =
      Repo.transaction(fn ->
        actor = actor && Repo.reload(actor)

        # nil actor means "system"
        if is_nil(actor) || Studios.is_user_in_studio?(actor, studio) || :admin in actor.roles ||
             :mod in actor.roles do
          max_idx =
            from(o in Offering, where: o.studio_id == ^studio.id, select: max(o.index))
            |> Repo.one!() ||
              0

          gallery_images =
            (gallery_images || [])
            |> Enum.with_index()
            |> Enum.map(fn {%Upload{} = upload, index} ->
              %GalleryImage{
                index: index,
                upload_id: upload.id
              }
            end)

          %Offering{
            studio_id: studio.id,
            gallery_imgs: gallery_images,
            index: max_idx + 1
          }
          |> Offering.changeset(attrs)
          |> Repo.insert()
        else
          {:error, :unauthorized}
        end
      end)

    ret
  end

  ## Updating

  @doc """
  Creates an update changeset for an Offering.
  """
  def change_offering(%Offering{} = offering, attrs \\ %{}) do
    Offering.changeset(offering, attrs)
  end

  @doc """
  Updates offering details.
  """
  def update_offering(%User{} = actor, %Offering{} = offering, false, attrs, gallery_images) do
    if :admin in actor.roles || :mod in actor.roles do
      update_offering(actor, offering, true, attrs, gallery_images)
    else
      {:error, :unauthorized}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def update_offering(actor, %Offering{} = offering, true, attrs, gallery_images) do
    {:ok, ret} =
      Repo.transaction(fn ->
        actor = actor && Repo.reload(actor)
        offering = Repo.reload(offering) |> Repo.preload(:options)

        # nil actors are meant to be used for "system" operations.
        if is_nil(actor) || Studios.is_user_in_studio?(actor, %Studio{id: offering.studio_id}) ||
             :admin in actor.roles ||
             :mod in actor.roles do
          open_before? = Repo.one(from o in Offering, where: o.id == ^offering.id, select: o.open)

          changeset =
            offering
            |> Repo.preload(:gallery_imgs)
            |> change_offering(attrs)

          changeset =
            if is_nil(gallery_images) do
              changeset
            else
              gallery_images =
                (gallery_images || [])
                |> Enum.with_index()
                |> Enum.map(fn {%Upload{} = upload, index} ->
                  %GalleryImage{
                    index: index,
                    upload_id: upload.id
                  }
                end)

              changeset |> Ecto.Changeset.put_assoc(:gallery_imgs, gallery_images)
            end

          ret = changeset |> Repo.update(returning: true)

          case ret do
            {:ok, changed} ->
              if !open_before? && changed.open do
                Notifications.offering_opened(changed)
              end

              {:ok, changed}

            {:error, error} ->
              {:error, error}
          end
        else
          {:error, :unauthorized}
        end
      end)

    ret
  end

  @doc """
  Archives an offering. This removes it from the visible list of offerings for
  its studio and prevents new requests.
  """
  def archive_offering(%User{} = actor, %Offering{} = offering, false) do
    if :admin in actor.roles || :mod in actor.roles do
      archive_offering(actor, offering, true)
    else
      {:error, :unauthorized}
    end
  end

  def archive_offering(actor, %Offering{} = offering, true) do
    {:ok, ret} =
      Repo.transaction(fn ->
        actor = actor && Repo.reload(actor)

        # nil actor means "system"
        if is_nil(actor) || Studios.is_user_in_studio?(actor, %Studio{id: offering.studio_id}) ||
             :admin in actor.roles ||
             :mod in actor.roles do
          {1, [new]} =
            from(o in Offering,
              where: o.id == ^offering.id,
              select: o
            )
            |> Repo.update_all(set: [index: nil, archived_at: NaiveDateTime.utc_now()])

          current_index = new.index

          if !is_nil(current_index) do
            {_, _} =
              from(
                o in Offering,
                where: o.index >= ^current_index and not is_nil(o.index),
                update: [set: [index: o.index - 1]]
              )
              |> Repo.update_all([])
          end

          {:ok, new}
        else
          {:error, :unauthorized}
        end
      end)

    ret
  end

  @doc """
  Unarchives an offering, making it available for new requests (if it's open).
  """
  def unarchive_offering(actor, %Offering{} = offering, false) do
    if is_nil(actor) || :admin in actor.roles || :mod in actor.roles do
      unarchive_offering(actor, offering, true)
    else
      {:error, :unauthorized}
    end
  end

  def unarchive_offering(actor, %Offering{} = offering, true) do
    {:ok, ret} =
      Repo.transaction(fn ->
        actor = actor && Repo.reload(actor)

        # nil actor means "system"
        if is_nil(actor) || Studios.is_user_in_studio?(actor, %Studio{id: offering.studio_id}) ||
             :admin in actor.roles ||
             :mod in actor.roles do
          max_idx =
            from(o in Offering, where: o.studio_id == ^offering.studio_id, select: max(o.index))
            |> Repo.one!() ||
              0

          {1, [new]} =
            from(o in Offering,
              where: o.id == ^offering.id,
              select: o
            )
            |> Repo.update_all(set: [index: max_idx + 1, archived_at: nil])

          {:ok, new}
        else
          {:error, :unauthorized}
        end
      end)

    ret
  end

  @doc """
  Changes the offering order in the Studio shop page. Does not affect ordering anywhere else.
  """
  def move_offering(actor, %Offering{} = offering, new_index, false) do
    if is_nil(actor) || :admin in actor.roles || :mod in actor.roles do
      move_offering(actor, offering, new_index, true)
    else
      {:error, :unauthorized}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def move_offering(actor, %Offering{} = offering, new_index, true) when new_index >= 0 do
    {:ok, ret} =
      Repo.transaction(fn ->
        actor = actor && Repo.reload(actor)

        # nil actor means "system"
        if is_nil(actor) || Studios.is_user_in_studio?(actor, %Studio{id: offering.studio_id}) ||
             :admin in actor.roles ||
             :mod in actor.roles do
          # "Remove" the existing offering
          {_, _} =
            from(o in Offering,
              where:
                o.studio_id ==
                  ^offering.studio_id and not is_nil(o.index) and o.index > ^offering.index,
              update: [set: [index: o.index - 1]]
            )
            |> Repo.update_all([])

          # Shift everything after new index to the right.
          {_, _} =
            from(o in Offering,
              where:
                o.studio_id == ^offering.studio_id and not is_nil(o.index) and
                  o.index >= ^new_index,
              update: [set: [index: o.index + 1]]
            )
            |> Repo.update_all([])

          {1, [o]} =
            from(o in Offering,
              where: o.id == ^offering.id,
              update: [set: [index: ^new_index]],
              select: o
            )
            |> Repo.update_all([])

          {:ok, o}
        else
          {:error, :unauthorized}
        end
      end)

    ret
  end

  def make_card_image!(%User{} = user, src, true, type, name) do
    # TODO: need two versions here, the smaller card image and "preview"
    # version for the offering page.
    upload = Uploads.save_file!(user, src, type, name)

    {:ok, card} =
      Thumbnailer.thumbnail(
        upload,
        dimensions: "1200",
        name: "card_image.jpg",
        callback: [__MODULE__.Notifications, :notify_images_updated]
      )

    card
  end

  def make_gallery_image!(%User{} = user, src, true, type, name) do
    upload = Uploads.save_file!(user, src, type, name)

    {:ok, image} =
      Thumbnailer.thumbnail(
        upload,
        dimensions: "1200",
        name: "gallery_image.jpg",
        callback: [__MODULE__.Notifications, :notify_images_updated]
      )

    image
  end

  ## Getting/Listing

  @doc """
  Gets a Studio's offering by its type name. Includes preloaded gallery
  uploads ad number of used slots.

  If an actor is provided, it will be used to check whether the actor is a
  studio member and is able to see hidden offerings.
  """
  def get_offering_by_type!(actor, %Studio{} = studio, type) do
    q =
      from o in Offering,
        as: :offering,
        join: s in assoc(o, :studio),
        as: :studio,
        left_lateral_join:
          gallery_uploads in subquery(
            from i in GalleryImage,
              where: i.offering_id == parent_as(:offering).id,
              join: u in assoc(i, :upload),
              group_by: [i.offering_id],
              select: %{uploads: fragment("array_agg(row_to_json(?))", u)}
          ),
        as: :gallery_uploads,
        left_lateral_join:
          used_slots in subquery(
            from c in Commission,
              where:
                c.offering_id == parent_as(:offering).id and
                  c.status not in [:withdrawn, :approved, :submitted, :rejected],
              group_by: [c.offering_id],
              select: %{used_slots: count(c.id)}
          ),
        as: :used_slots,
        where: o.studio_id == ^studio.id and o.type == ^type,
        select:
          merge(o, %{
            used_slots: coalesce(used_slots.used_slots, 0),
            gallery_uploads:
              type(
                coalesce(
                  gallery_uploads.uploads,
                  fragment("ARRAY[]::json[]")
                ),
                {:array, Upload}
              )
          })

    q =
      if actor do
        q
        |> join(:inner, [], actor in User, as: :actor, on: actor.id == ^actor.id)
        |> join(:left, [studio: studio, actor: actor], us in "users_studios",
          as: :actor_member?,
          on: us.studio_id == studio.id and actor.id == us.user_id
        )
        |> where([offering: o, actor_member?: us], not is_nil(us) or not o.hidden)
        |> join(:left, [offering: o], sub in OfferingSubscription,
          on:
            sub.user_id == ^actor.id and sub.offering_id == o.id and
              sub.silenced != true,
          as: :subscribed
        )
        |> select_merge([subscribed: sub], %{
          user_subscribed?: not is_nil(sub.id)
        })
      else
        q
        |> where([offering: o], not o.hidden)
      end

    q
    |> Repo.one!()
    |> Repo.preload([:options, :studio, :card_img])
  end

  @doc """
  Calculates the offering's base price. Assumes the offering has been loaded
  through `list_offerings/1`, which populates the relevant virtual field.
  """
  def offering_base_price(%Offering{} = offering) do
    if Enum.empty?(offering.option_prices) do
      nil
    else
      offering.option_prices
      |> Enum.reduce(%{}, fn price, acc ->
        current =
          Map.get(
            acc,
            price.currency,
            Money.new(0, price.currency)
          )

        Map.put(acc, price.currency, Money.add(current, price))
      end)
    end
  end

  @doc """
  Calculates the offering's available slots. If `reload` is false, this
  assumes the offering has been loaded through `list_offerings/1`, which
  populates the relevant virtual field.
  """
  def offering_available_slots(%Offering{} = offering, reload \\ false) do
    {slots, used_slots} =
      if reload do
        Repo.one(
          from o in Offering,
            left_join: c in assoc(o, :commissions),
            on: c.status not in [:withdrawn, :approved, :submitted, :rejected],
            where: o.id == ^offering.id,
            group_by: [o.id, o.slots],
            select: {o.slots, count(c)}
        )
      else
        {offering.slots, offering.used_slots}
      end

    cond do
      is_nil(slots) ->
        nil

      used_slots > slots ->
        0

      true ->
        slots - used_slots
    end
  end

  @doc """
  Calculates the offering's available pending proposals.
  """
  def offering_available_proposals(%Offering{} = offering) do
    {max, count} =
      Repo.one(
        from(o in Offering,
          left_join: c in Commission,
          on: c.offering_id == o.id and c.status == :submitted,
          where: o.id == ^offering.id,
          group_by: [o.id, o.max_proposals],
          select: {o.max_proposals, count(c)}
        )
      )

    cond do
      is_nil(max) ->
        nil

      count > max ->
        0

      true ->
        max - count
    end
  end

  @doc """
  Lists images for an offering's samples gallery, in the order they've been
  sorted into. Returns the Uploads themselves.
  """
  def offering_gallery_uploads(%Offering{} = offering) do
    from(i in GalleryImage,
      join: u in assoc(i, :upload),
      where: i.offering_id == ^offering.id,
      order_by: [asc: i.index],
      select: u
    )
    |> Repo.all()
  end

  @doc """
  Über query for listing offerings across various use cases on the site.
  Accepts several options that affect its behavior.

  ## Options

    * `:page` - Page number to return results for. Defaults to 1.
    * `:page_size` - Number of results to return per page. Defaults to 20.
    * `:include_pending?` - Whether to include offerings for studios whose charges
      are not enabled. Typically this is only a thing for testing and dealing
      with dev seeds. Defaults to false.
    * `:include_disabled?` - Whether to include offerings for disabled studios.
      Defaults to false.
    * `:include_archived?` - Whether to include archived offerings in the
      listing. Defaults to false.
    * `:query` - Websearch-syntax search query used to match against the
      offering's `search_vector`. Defaults to nil.
    * `:studio` - Filter offerings only to those belonging to the given
      `%Studio{}`.
    * `:current_user` - The current user. If given, it's used to:
      * Filter mature content based on the user's settings.
      * Filter offerings based on the user's muted word settings.
      * Remove offerings from studios that have blocked this user.
      * Populate the `user_subscribed?` field based on the user's settings.
    * `:order_by` - The order to sort the offerings by. Some of these will
      also filter some offerings out.
      * `:index` - Sort by the offering's index in its Studio shop.
      * `:featured` - Orders by the newest offerings/studio pair. Also filters
        out any offerings that don't have all of: a decription, card image,
        and gallery images.
      * `:oldest` - Show oldest offerings first.
      * `:newest` - Show newest offerings first.
      * `:price_high` - Show highest-priced offerings first.
      * `:price_low` - Show lowest-priced offerings first.
    * `:include_closed?` - Whether to show closed offerings. Defaults to false.
    * `:related_to` - Accepts another `%Offering{}` and returns offerings that
      are related to it. Defaults to nil.

  """
  def list_offerings(opts \\ []) do
    from(o in Offering,
      as: :offering,
      join: s in assoc(o, :studio),
      as: :studio,
      left_lateral_join:
        used_slots in subquery(
          from c in Commission,
            where:
              c.offering_id == parent_as(:offering).id and
                c.status not in [:withdrawn, :approved, :submitted, :rejected],
            group_by: [c.offering_id],
            select: %{used_slots: count(c.id)}
        ),
      as: :used_slots,
      left_lateral_join:
        default_prices in subquery(
          from oo in OfferingOption,
            where: oo.offering_id == parent_as(:offering).id and oo.default,
            group_by: [oo.offering_id],
            select: %{
              prices:
                type(fragment("array_agg(?)", oo.price), {:array, Money.Ecto.Composite.Type}),
              # NB(zkat): This is hacky to the point of uselessness if we end up
              # having a ton of different currencies listed, but it's serviceable for now.
              sum: fragment("sum((?).amount)", oo.price)
            }
        ),
      as: :default_prices,
      left_lateral_join:
        gallery_uploads in subquery(
          from i in GalleryImage,
            where: i.offering_id == parent_as(:offering).id,
            join: u in assoc(i, :upload),
            group_by: [i.offering_id],
            select: %{uploads: fragment("array_agg(row_to_json(?))", u)}
        ),
      as: :gallery_uploads,
      select:
        merge(o, %{
          studio: s,
          used_slots: coalesce(used_slots.used_slots, 0),
          gallery_uploads:
            type(
              coalesce(
                gallery_uploads.uploads,
                fragment("ARRAY[]::json[]")
              ),
              {:array, Upload}
            ),
          option_prices:
            type(
              coalesce(default_prices.prices, fragment("ARRAY[]::money_with_currency[]")),
              {:array, Money.Ecto.Composite.Type}
            )
        })
    )
    |> filter_query(opts)
    |> filter_include_pending?(opts)
    |> filter_include_disabled?(opts)
    |> filter_include_archived?(opts)
    |> filter_studio(opts)
    |> filter_current_user(opts)
    |> filter_order_by(opts)
    |> filter_include_closed?(opts)
    |> filter_related_to(opts)
    |> Repo.paginate(
      page: Keyword.get(opts, :page, 1),
      page_size: Keyword.get(opts, :page_size, 20)
    )
  end

  defp filter_query(q, opts) do
    case Keyword.fetch(opts, :query) do
      {:ok, nil} ->
        q

      {:ok, query} ->
        q
        |> where([o], fragment("websearch_to_tsquery(?) @@ (?).search_vector", ^query, o))

      :error ->
        q
    end
  end

  defp filter_include_pending?(q, opts) do
    case Keyword.fetch(opts, :include_pending?) do
      {:ok, true} ->
        q

      _ ->
        q
        |> where([studio: s], s.stripe_charges_enabled == true)
    end
  end

  defp filter_include_disabled?(q, opts) do
    case Keyword.fetch(opts, :include_disabled?) do
      {:ok, true} ->
        q

      _ ->
        q
        |> join(:left, [studio: s], disable_info in assoc(s, :disable_info), as: :disable_info)
        |> where([disable_info: disable_info], is_nil(disable_info))
    end
  end

  defp filter_include_archived?(q, opts) do
    case Keyword.fetch(opts, :include_archived?) do
      {:ok, true} ->
        q |> where([o], is_nil(o.archived_at))

      _ ->
        q
    end
  end

  defp filter_studio(q, opts) do
    case Keyword.fetch(opts, :studio) do
      {:ok, nil} ->
        q

      {:ok, %Studio{} = studio} ->
        q |> where([o], o.studio_id == ^studio.id)

      :error ->
        q
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp filter_current_user(q, opts) do
    case Keyword.fetch(opts, :current_user) do
      {:ok, %User{} = current_user} ->
        q
        |> join(:inner, [], user in User, on: user.id == ^current_user.id, as: :current_user)
        |> join(:left, [studio: studio, current_user: current_user], us in "users_studios",
          as: :current_user_member?,
          on: us.studio_id == studio.id and current_user.id == us.user_id
        )
        |> where(
          [offering: o, current_user: current_user, current_user_member?: current_user_member?],
          not is_nil(current_user_member?) or
            o.mature != true or (o.mature == true and current_user.mature_ok == true)
        )
        |> where(
          [offering: o, current_user_member?: current_user_member?],
          not is_nil(current_user_member?) or o.hidden == false
        )
        |> join(:left, [offering: o, current_user: current_user], sub in OfferingSubscription,
          on:
            sub.user_id == current_user.id and sub.offering_id == o.id and
              sub.silenced != true,
          as: :subscription
        )
        |> where(
          [o, current_user: current_user],
          is_nil(current_user.muted) or
            not fragment("(?).muted_filter_query @@ (?).search_vector", current_user, o)
        )
        |> join(:left, [studio: s], block in assoc(s, :blocklist), as: :blocklist)
        |> where(
          [blocklist: block, current_user: u],
          :admin in u.roles or :mod in u.roles or is_nil(block) or block.user_id != u.id
        )
        |> select_merge([o, subscription: sub], %{
          user_subscribed?: not is_nil(sub.id)
        })

      _ ->
        q
        |> where([o], o.mature != true and o.hidden == false)
        |> select_merge(%{user_subscribed?: false})
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp filter_order_by(q, opts) do
    case Keyword.fetch(opts, :order_by) do
      {:ok, nil} ->
        q

      {:ok, :index} ->
        q
        |> order_by([o], [fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", o.index), o.index])

      {:ok, :featured} ->
        q
        |> order_by([o, studio: s], [{:desc, o.inserted_at}, {:desc, s.inserted_at}])
        |> where([o], not is_nil(o.description) and o.description != "")
        |> where([o], not is_nil(o.card_img_id))
        |> where(
          [gallery_uploads: gallery_uploads],
          not is_nil(gallery_uploads.uploads) and
            fragment("array_length(?, 1) > 0", gallery_uploads.uploads)
        )

      {:ok, :oldest} ->
        q
        |> order_by([o], [{:asc, o.inserted_at}])

      {:ok, :newest} ->
        q
        |> order_by([o], [{:desc, o.inserted_at}])

      {:ok, :price_high} ->
        q
        |> order_by([default_prices: default_prices], desc: default_prices.sum)

      {:ok, :price_low} ->
        q
        |> order_by([default_prices: default_prices], asc: default_prices.sum)

      :error ->
        q
    end
  end

  defp filter_include_closed?(q, opts) do
    case Keyword.fetch(opts, :include_closed?) do
      {:ok, true} ->
        q

      {:ok, _} ->
        q |> where([o], o.open == true)

      :error ->
        q |> where([o], o.open == true)
    end
  end

  defp filter_related_to(q, opts) do
    case Keyword.fetch(opts, :related_to) do
      {:ok, %Offering{} = related} ->
        q
        |> join(:inner, [o], rel in Offering,
          on: rel.id == ^related.id and rel.id != o.id,
          as: :related_to
        )
        |> where(
          [o, related_to: related_to],
          # TODO: Cache this db-side somehow? This seems like a lot of work
          # to be doing on the fly.
          fragment(
            "to_tsquery('banchan_fts', array_to_string(tsvector_to_array(?), ' | ')) @@ ?",
            related_to.search_vector,
            o.search_vector
          )
        )

      :error ->
        q
    end
  end
end
