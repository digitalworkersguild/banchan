defmodule Banchan.Commissions do
  @moduledoc """
  The Commissions context.
  """

  import Ecto.Query, warn: false
  alias Banchan.Repo

  alias Banchan.Commissions.{Commission, Event}

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
  def get_commission!(studio, public_id) do
    Repo.one!(
      from c in Commission,
        where: c.studio_id == ^studio.id and c.public_id == ^public_id
    )
  end

  @doc """
  Creates a commission.

  ## Examples

      iex> create_commission(offering, %{field: value})
      {:ok, %Commission{}}

      iex> create_commission(offering, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_commission(studio, offering, attrs \\ %{}) do
    %Commission{public_id: Commission.gen_public_id, studio: studio, offering: offering}
    |> Commission.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a commission.

  ## Examples

      iex> update_commission(commission, %{field: new_value})
      {:ok, %Commission{}}

      iex> update_commission(commission, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_commission(%Commission{} = commission, attrs) do
    commission
    |> Commission.changeset(attrs)
    |> Repo.update()
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
  def list_commission_events do
    Repo.all(Event)
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

      iex> create_event(%{field: value})
      {:ok, %Event{}}

      iex> create_event(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_event(attrs \\ %{}) do
    %Event{}
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
