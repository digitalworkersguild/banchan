defmodule BanchanWeb.StudioLive.Offerings.Edit do
  @moduledoc """
  LiveView for creating new studio offerings.
  """
  use BanchanWeb, :surface_view

  alias Banchan.Offerings

  import BanchanWeb.StudioLive.Helpers

  alias BanchanWeb.StudioLive.Components

  @impl true
  def mount(%{"offering_type" => offering_type} = params, _session, socket) do
    socket = assign_studio_defaults(params, socket, true, false)

    offering =
      Offerings.get_offering_by_type!(
        socket.assigns.current_user,
        socket.assigns.studio,
        offering_type
      )

    {:ok, assign(socket, offering: offering, gallery_images: nil)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(uri: uri)}
  end

  def handle_info({:updated_gallery_images, _, images}, socket) do
    {:noreply,
     socket
     |> assign(gallery_images: images)}
  end

  def handle_info(%{event: "follower_count_changed", payload: new_count}, socket) do
    {:noreply, socket |> assign(followers: new_count)}
  end

  @impl true
  def render(assigns) do
    ~F"""
    <Components.StudioLayout
      id="studio-layout"
      current_user={@current_user}
      flashes={@flash}
      studio={@studio}
      followers={@followers}
      current_user_member?={@current_user_member?}
      tab={:shop}
      uri={@uri}
    >
      <div>
        <div class="p-6 max-w-lg mx-auto">
          <h1 class="text-3xl">Edit Offering</h1>
          <div class="divider" />
          <Components.Offering
            id="edit-offering"
            current_user={@current_user}
            current_user_member?={@current_user_member?}
            studio={@studio}
            offering={@offering}
            gallery_images={@gallery_images}
          />
        </div>
      </div>
    </Components.StudioLayout>
    """
  end
end
