defmodule BanchanWeb.StudioLive.Shop do
  @moduledoc """
  LiveView for viewing individual Studios
  """
  use BanchanWeb, :surface_view

  alias Banchan.Studios

  alias Surface.Components.LiveRedirect

  alias BanchanWeb.Components.{Button, Card}
  alias BanchanWeb.Endpoint
  alias BanchanWeb.StudioLive.Components.{CommissionCard, StudioLayout}
  import BanchanWeb.StudioLive.Helpers

  @impl true
  def mount(params, session, socket) do
    socket = assign_defaults(session, socket, false)
    socket = assign_studio_defaults(params, socket, false, false)
    studio = socket.assigns.studio
    members = Studios.list_studio_members(studio)
    offerings = Studios.list_studio_offerings(studio, socket.assigns.current_user_member?)
    summary = studio.summary && HtmlSanitizeEx.markdown_html(Earmark.as_html!(studio.summary))

    Studios.subscribe_to_stripe_state(studio)

    stripe_onboarding_url =
      if !Studios.charges_enabled?(studio) && socket.assigns.current_user_member? do
        Routes.stripe_account_path(Endpoint, :account_link, studio.handle)
      else
        nil
      end

    {:ok,
     assign(socket,
       members: members,
       offerings: offerings,
       summary: summary,
       stripe_onboarding_url: stripe_onboarding_url
     )}
  end

  @impl true
  def handle_info(%{event: "charges_state_changed", payload: enabled?}, socket) do
    {:noreply,
     socket
     |> assign(studio: %{socket.assigns.studio | stripe_charges_enabled: enabled?})}
  end

  @impl true
  def handle_info(%{event: "details_submitted_changed", payload: submitted?}, socket) do
    {:noreply,
     socket
     |> assign(studio: %{socket.assigns.studio | stripe_details_submitted: submitted?})}
  end

  @impl true
  def handle_event("recheck_stripe", _, socket) do
    # No need to refresh the studio here. It'll get reloaded by the PubSub event(s)
    Studios.charges_enabled?(socket.assigns.studio, true)
    {:noreply, socket}
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
      <div class="grid grid-cols-3 justify-items-stretch gap-6">
        {#if Studios.charges_enabled?(@studio)}
          <div class="offerings">
            {#for offering <- @offerings}
              <CommissionCard studio={@studio} offering={offering} />
            {#else}
              This shop has no offerings currently available. Check back in later!
            {/for}
            {#if @current_user_member?}
              <div class="">
                <LiveRedirect
                  to={Routes.studio_offerings_index_path(Endpoint, :index, @studio.handle)}
                  class="btn btn-sm text-center rounded-full m-5 btn-warning"
                >Manage Offerings</LiveRedirect>
              </div>
            {/if}
          </div>
        {#elseif @current_user_member? && !@studio.stripe_details_submitted}
          <p>You need to <a class="hover:underline font-bold" href={@stripe_onboarding_url}>onboard your studio on Stripe</a>

            <Button click="recheck_stripe" label="Recheck" />
          </p>
        {#elseif @current_user_member? && !@studio.stripe_charges_enabled}
          <p>Details have been submitted to Stripe. Please wait while charges are enabled.

            <Button click="recheck_stripe" label="Recheck" />
          </p>
        {#else}
          <p>This studio is still working on opening its doors. Check back in soon!</p>
        {/if}
        <div class="col-start-3">
          {#if @summary}
            <div class="bg-base-200 text-base-content">
              <Card>
                <:header>
                  Summary
                </:header>
                <div class="content leading-loose">{raw(@summary)}</div>
              </Card>
            </div>
          {/if}
          <div class="shadow bg-base-200 text-base-content p-6">
            <h2 class="text-xl">Members</h2>
            <div class="studio-members grid grid-cols-4 gap-1">
              {#for member <- @members}
                <figure class="col-span-1">
                  <LiveRedirect to={Routes.denizen_show_path(Endpoint, :show, member.handle)}>
                    <img
                      alt={member.name}
                      class="rounded-full h-24 w-24 flex items-center justify-center"
                      src={Routes.static_path(Endpoint, "/images/denizen_default_icon.png")}
                    />
                  </LiveRedirect>
                </figure>
              {/for}
            </div>
          </div>
        </div>
      </div>
    </StudioLayout>
    """
  end
end
