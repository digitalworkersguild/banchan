defmodule Banchan.OfferingsTest do
  @moduledoc """
  Tests for the Banchan.Offerings context.
  """
  use Banchan.DataCase, async: true

  import Banchan.AccountsFixtures
  import Banchan.CommissionsFixtures
  import Banchan.OfferingsFixtures
  import Banchan.StudiosFixtures

  alias Banchan.Commissions
  alias Banchan.Notifications
  alias Banchan.Offerings
  alias Banchan.Studios

  setup do
    on_exit(fn -> Notifications.wait_for_notifications() end)
  end

  describe "offering notifications" do
    test "notify offering and studio subscribers when an offering opens" do
      client = user_fixture()
      client2 = user_fixture()
      client3 = user_fixture()
      artist = user_fixture()
      studio = studio_fixture([artist])

      offering =
        offering_fixture(studio, %{
          slots: nil
        })

      Offerings.Notifications.subscribe_user!(client, offering)
      Studios.Notifications.follow_studio!(studio, client2)

      Notifications.mark_all_as_read(client)
      Notifications.mark_all_as_read(artist)

      Offerings.update_offering(artist, offering |> Repo.reload(), true, %{open: false}, nil)
      Offerings.update_offering(artist, offering |> Repo.reload(), true, %{open: true}, nil)

      Notifications.wait_for_notifications()

      # Artist does not follow the studio, so no notifs.
      assert [] = Notifications.unread_notifications(artist).entries

      # User is specifically-subscribed
      assert [%{short_body: "Commission slots are now available for " <> _}] =
               Notifications.unread_notifications(client).entries

      # User follows studio
      assert [%{short_body: "Commission slots are now available for " <> _}] =
               Notifications.unread_notifications(client2).entries

      # And this rando isn't at all
      assert [] = Notifications.unread_notifications(client3).entries
    end

    test "notify when there's a new offering" do
      # TODO
    end
  end

  describe "offering slots" do
    test "with no slot limit" do
      artist = user_fixture()
      studio = studio_fixture([artist])
      client = user_fixture()

      offering =
        offering_fixture(studio, %{
          slots: nil
        })

      assert nil == offering.slots
      assert nil == Offerings.offering_available_slots(offering)

      # Can freely create commissions
      {:ok, _comm} =
        Commissions.create_commission(
          client,
          studio,
          offering,
          [],
          [],
          %{
            title: "some title",
            description: "Some Description",
            tos_ok: true
          }
        )

      {:ok, _comm} =
        Commissions.create_commission(
          client,
          studio,
          offering,
          [],
          [],
          %{
            title: "some title",
            description: "Some Description",
            tos_ok: true
          }
        )
    end

    test "with slot limit" do
      artist = user_fixture()
      studio = studio_fixture([artist])
      client = user_fixture()

      offering =
        offering_fixture(studio, %{
          slots: 3
        })

      get_slots = fn ->
        Offerings.list_offerings(
          studio: studio,
          current_user: client,
          include_closed?: true,
          include_pending?: true
        ).entries
        |> List.first()
        |> Offerings.offering_available_slots()
      end

      assert 3 == get_slots.()

      comm1 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      assert 3 == get_slots.()

      Commissions.update_status(artist, comm1, :accepted)
      assert 2 == get_slots.()

      Commissions.update_status(artist, comm1 |> Repo.reload(), :in_progress)
      assert 2 == get_slots.()

      Commissions.update_status(artist, comm1 |> Repo.reload(), :ready_for_review)
      assert 2 == get_slots.()

      comm2 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      comm3 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      comm4 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      # No change to slots because commissions aren't accepted yet.
      assert 2 == get_slots.()

      # Now we accept each new commission
      Commissions.update_status(artist, comm2, :accepted)
      assert 1 == get_slots.()

      Commissions.update_status(artist, comm3, :accepted)
      assert 0 == get_slots.()

      # Creating new commissions is blocked.
      assert {:error, :offering_closed} ==
               Commissions.create_commission(
                 client,
                 studio,
                 offering,
                 [],
                 [],
                 %{
                   title: "some title",
                   description: "Some Description",
                   tos_ok: true
                 }
               )

      # Overflow is fine. Just get 0 back.
      Commissions.update_status(artist, comm4, :accepted)
      assert 0 == get_slots.()

      # We're still dealing with the overflow, so still 0
      Commissions.update_status(client, comm1 |> Repo.reload(), :approved)
      assert 0 == get_slots.()

      # Still can't make that comm...
      assert {:error, :offering_closed} ==
               Commissions.create_commission(
                 client,
                 studio,
                 offering,
                 [],
                 [],
                 %{
                   title: "some title",
                   description: "Some Description",
                   tos_ok: true
                 }
               )

      # Give back slots one by one.
      Commissions.update_status(artist, comm2 |> Repo.reload(), :ready_for_review)
      Commissions.update_status(client, comm2 |> Repo.reload(), :approved)
      assert 1 == get_slots.()

      # Still closed!
      assert {:error, :offering_closed} ==
               Commissions.create_commission(
                 client,
                 studio,
                 offering,
                 [],
                 [],
                 %{
                   title: "some title",
                   description: "Some Description",
                   tos_ok: true
                 }
               )

      # Offering must be manually reopened
      assert {:ok, _} =
               Offerings.update_offering(
                 artist,
                 offering |> Repo.reload(),
                 true,
                 %{open: true},
                 nil
               )

      # Now we can make comms again!
      {:ok, _comm} =
        Commissions.create_commission(
          client,
          studio,
          offering,
          [],
          [],
          %{
            title: "some title",
            description: "Some Description",
            tos_ok: true
          }
        )

      Commissions.update_status(artist, comm3 |> Repo.reload(), :ready_for_review)
      Commissions.update_status(client, comm3 |> Repo.reload(), :approved)
      assert 2 == get_slots.()

      Commissions.update_status(artist, comm4 |> Repo.reload(), :ready_for_review)
      Commissions.update_status(client, comm4 |> Repo.reload(), :approved)
      assert 3 == get_slots.()
    end
  end

  describe "offering with max proposals" do
    test "with no proposal" do
      artist = user_fixture()
      studio = studio_fixture([artist])
      client = user_fixture()

      offering =
        offering_fixture(studio, %{
          max_proposals: nil
        })

      assert nil == offering.max_proposals
      assert nil == Offerings.offering_available_proposals(offering)

      # Can freely create commissions
      {:ok, _comm} =
        Commissions.create_commission(
          client,
          studio,
          offering,
          [],
          [],
          %{
            title: "some title",
            description: "Some Description",
            tos_ok: true
          }
        )

      {:ok, _comm} =
        Commissions.create_commission(
          client,
          studio,
          offering,
          [],
          [],
          %{
            title: "some title",
            description: "Some Description",
            tos_ok: true
          }
        )
    end

    test "with proposal limit" do
      artist = user_fixture()
      studio = studio_fixture([artist])
      client = user_fixture()

      offering =
        offering_fixture(studio, %{
          max_proposals: 3
        })

      assert 3 == offering.max_proposals
      assert 3 == Offerings.offering_available_proposals(offering)

      comm1 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      assert 2 == Offerings.offering_available_proposals(offering)

      Commissions.update_status(artist, comm1, :accepted)
      assert 3 == Offerings.offering_available_proposals(offering)

      Commissions.update_status(artist, comm1 |> Repo.reload(), :in_progress)
      assert 3 == Offerings.offering_available_proposals(offering)

      Commissions.update_status(artist, comm1 |> Repo.reload(), :ready_for_review)
      assert 3 == Offerings.offering_available_proposals(offering)

      Commissions.update_status(client, comm1 |> Repo.reload(), :approved)
      assert 3 == Offerings.offering_available_proposals(offering)

      comm2 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      assert 2 == Offerings.offering_available_proposals(offering)

      comm3 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      assert 1 == Offerings.offering_available_proposals(offering)

      comm4 =
        commission_fixture(%{
          client: client,
          artist: artist,
          studio: studio,
          offering: offering
        })

      assert 0 == Offerings.offering_available_proposals(offering)

      # Creating new commissions is blocked.
      assert {:error, :offering_closed} ==
               Commissions.create_commission(
                 client,
                 studio,
                 offering,
                 [],
                 [],
                 %{
                   title: "some title",
                   description: "Some Description",
                   tos_ok: true
                 }
               )

      # Now we accept each new commission
      Commissions.update_status(artist, comm2, :accepted)
      assert 1 == Offerings.offering_available_proposals(offering)

      Commissions.update_status(artist, comm3, :accepted)
      assert 2 == Offerings.offering_available_proposals(offering)

      Commissions.update_status(artist, comm4, :accepted)
      assert 3 == Offerings.offering_available_proposals(offering)

      # But we're still closed.
      assert {:error, :offering_closed} ==
               Commissions.create_commission(
                 client,
                 studio,
                 offering,
                 [],
                 [],
                 %{
                   title: "some title",
                   description: "Some Description",
                   tos_ok: true
                 }
               )

      # Offering must be manually reopened
      assert {:ok, _} =
               Offerings.update_offering(
                 artist,
                 offering |> Repo.reload(),
                 true,
                 %{open: true},
                 nil
               )

      # Now we can start making comms again!
      assert {:ok, _comm} =
               Commissions.create_commission(
                 client,
                 studio,
                 offering,
                 [],
                 [],
                 %{
                   title: "some title",
                   description: "Some Description",
                   tos_ok: true
                 }
               )
    end
  end
end
