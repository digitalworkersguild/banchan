defmodule Banchan.Commissions do
  @moduledoc """
  The Commissions context.
  """

  import Ecto.Query, warn: false
  alias Banchan.Repo

  alias Banchan.Accounts.User
  alias Banchan.Commissions.{Commission, Event, LineItem}
  alias Banchan.Offerings
  alias Banchan.Offerings.OfferingOption

  @doc """
  Returns the list of commissions.

  ## Examples

      iex> list_commissions(studio)
      [%Commission{}, ...]

  """
  def list_commissions(studio) do
    Repo.all(
      from c in Commission,
        where: c.studio_id == ^studio.id
    )
  end

  @doc """
  Gets a single commission for a studio.

  Raises `Ecto.NoResultsError` if the Commission does not exist.

  ## Examples

      iex> get_commission!(studio, "lkajweirj0")
      %Commission{}

      iex> get_commission!(studio, "oiwejoa13d")
      ** (Ecto.NoResultsError)

  """
  def get_commission!(studio, public_id, current_user, current_user_member?) do
    Repo.one!(
      from c in Commission,
        where:
          c.studio_id == ^studio.id and c.public_id == ^public_id and
            (^current_user_member? or c.client_id == ^current_user.id),
        preload: [events: [:actor], line_items: [:option], offering: [:options]]
    )
  end

  @doc """
  Creates a commission.

  ## Examples

      iex> create_commission(actor, studio, offering, %{field: value})
      {:ok, %Commission{}}

      iex> create_commission(actor, studio, offering, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_commission(actor, studio, offering, line_items, attrs \\ %{}) do
    {:ok, ret} =
      Repo.transaction(fn ->
        available_slot_count = Offerings.offering_available_slots(offering)
        available_proposal_count = Offerings.offering_available_proposals(offering)

        maybe_close_offering(offering, available_slot_count, available_proposal_count)

        cond do
          !is_nil(available_slot_count) && available_slot_count <= 0 ->
            {:error, :no_slots_available}

          !is_nil(available_proposal_count) && available_proposal_count <= 0 ->
            {:error, :no_proposals_available}

          true ->
            insert_commission(actor, studio, offering, line_items, attrs)
        end
      end)

    ret
  end

  defp maybe_close_offering(offering, available_slot_count, available_proposal_count) do
    # Make sure we close the offering if we're out of slots or proposals.
    close_slots = !is_nil(available_slot_count) && available_slot_count <= 1
    close_proposals = !is_nil(available_proposal_count) && available_proposal_count <= 1
    close = close_slots || close_proposals

    if close do
      {:ok, _} = Offerings.update_offering(offering, %{open: false})
    end
  end

  defp insert_commission(actor, studio, offering, line_items, attrs) do
    %Commission{
      public_id: Commission.gen_public_id(),
      studio: studio,
      offering: offering,
      client: actor,
      line_items: line_items,
      events: [
        %{
          actor: actor,
          type: :comment,
          text: Map.get(attrs, "description", "")
        }
      ]
    }
    |> Commission.changeset(attrs)
    |> Repo.insert()
  end

  def update_status(%User{} = actor, %Commission{} = commission, status) do
    {:ok, ret} =
      Repo.transaction(fn ->
        {:ok, commission} =
          commission
          |> Commission.changeset(%{status: status})
          |> Repo.update()

        {:ok, event} = create_event(:status, actor, commission, %{status: status})

        {:ok, {commission, [event]}}
      end)

    ret
  end

  def add_line_item(%User{} = actor, %Commission{} = commission, option) do
    {:ok, ret} =
      Repo.transaction(fn ->
        line_item =
          case option do
            %OfferingOption{} ->
              %LineItem{
                option: option,
                amount: option.price || Money.new(0, :USD),
                name: option.name,
                description: option.description
              }

            %{amount: amount, name: name, description: description} ->
              %LineItem{
                option: nil,
                amount: amount,
                name: name,
                description: description
              }
          end

        case commission
             |> Commission.changeset(%{
               tos_ok: true
             })
             |> Ecto.Changeset.put_assoc(:line_items, commission.line_items ++ [line_item])
             |> Repo.update() do
          {:error, err} ->
            {:error, err}

          {:ok, commission} ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case create_event(:line_item_added, actor, commission, %{amount: line_item.amount}) do
              {:error, err} -> {:error, err}
              {:ok, event} -> {:ok, {commission, [event]}}
            end
        end
      end)

    ret
  end

  def remove_line_item(%User{} = actor, %Commission{} = commission, line_item) do
    {:ok, ret} =
      Repo.transaction(fn ->
        line_items = Enum.filter(commission.line_items, &(&1.id != line_item.id))

        case commission
             |> Commission.changeset(%{
               tos_ok: true
             })
             |> Ecto.Changeset.put_assoc(:line_items, line_items)
             |> Repo.update() do
          {:error, err} ->
            {:error, err}

          {:ok, commission} ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case create_event(:line_item_removed, actor, commission, %{amount: line_item.amount}) do
              {:error, err} -> {:error, err}
              {:ok, event} -> {:ok, {commission, [event]}}
            end
        end
      end)

    ret
  end

  @doc """
  Deletes a commission.

  ## Examples

      iex> delete_commission(commission)
      {:ok, %Commission{}}

      iex> delete_commission(commission)
      {:error, %Ecto.Changeset{}}

  """
  def delete_commission(%Commission{} = commission) do
    Repo.delete(commission)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking commission changes.

  ## Examples

      iex> change_commission(commission)
      %Ecto.Changeset{data: %Commission{}}

  """
  def change_commission(%Commission{} = commission, attrs \\ %{}) do
    Commission.changeset(commission, attrs)
  end

  @doc """
  Returns the list of commission_events.

  ## Examples

      iex> list_commission_events()
      [%Event{}, ...]

  """
  def list_commission_events(commission) do
    Repo.all(from e in Event, where: e.commission_id == ^commission.id)
  end

  @doc """
  Gets a single event.

  Raises `Ecto.NoResultsError` if the Event does not exist.

  ## Examples

      iex> get_event!(123)
      %Event{}

      iex> get_event!(456)
      ** (Ecto.NoResultsError)

  """
  def get_event!(id), do: Repo.get!(Event, id)

  @doc """
  Creates a event.

  ## Examples

      iex> create_event(actor, commission, %{field: value})
      {:ok, %Event{}}

      iex> create_event(actor, commission, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_event(type, %User{} = actor, %Commission{} = commission, attrs \\ %{})
      when is_atom(type) do
    %Event{type: type, commission: commission, actor: actor}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a event.

  ## Examples

      iex> update_event(event, %{field: new_value})
      {:ok, %Event{}}

      iex> update_event(event, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_event(%Event{} = event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
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
end
