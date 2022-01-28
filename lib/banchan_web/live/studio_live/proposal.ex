defmodule BanchanWeb.StudioLive.Proposal do
  @moduledoc """
  Subpage for creating a new commission based on an offering type.
  """
  use BanchanWeb, :surface_view

  alias Banchan.Commissions
  alias Banchan.Commissions.Commission
  alias Banchan.Offerings

  alias BanchanWeb.StudioLive.Components.StudioLayout

  alias Surface.Components.Form
  alias Surface.Components.Form.Submit

  alias BanchanWeb.Components.Card
  alias BanchanWeb.Components.Form.{Checkbox, TextArea, TextInput}
  alias BanchanWeb.Endpoint
  alias BanchanWeb.StudioLive.Components.Commissions.Attachments
  import BanchanWeb.StudioLive.Helpers

  @impl true
  def mount(%{"offering_type" => offering_type} = params, session, socket) do
    socket = assign_defaults(session, socket, true)
    socket = assign_studio_defaults(params, socket, false)
    offering = Offerings.get_offering_by_type!(offering_type)
    terms = HtmlSanitizeEx.markdown_html(Earmark.as_html!(offering.terms || ""))

    if offering.open do
      {:ok,
      assign(socket,
        changeset: Commission.changeset(%Commission{}, %{}),
        offering: offering,
        terms: terms
      )}
    else
      # TODO: Maybe show this on this page itself?
      socket = put_flash(socket, :error, "This commission offering is currently closed. Please try signing up for notifications for when it opens instead.")
      {:ok,
        push_redirect(socket, to: Routes.studio_shop_path(Endpoint, :show, socket.assigns.studio.handle))
      }
    end
  end

  @impl true
  def handle_event("change", %{"commission" => commission}, socket) do
    changeset =
      %Commission{}
      |> Commissions.change_commission(commission)
      |> Map.put(:action, :update)

    socket = assign(socket, changeset: changeset)
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
      <div class="grid grid-cols-5 gap-4">
        <div class="col-span-3">
          <h1 class="text-2xl">{@offering.name}</h1>
          <h2 class="text-xl">{@offering.description}</h2>
          <Form for={@changeset} change="change" submit="submit">
            <div class="block">
              <TextInput name={:title} opts={required: true, placeholder: "A Brief Title"} />
              <TextArea name={:description} opts={required: true, placeholder: "Here's what I'd like..."} />
            </div>
            <div class="content block">
              <h3>Terms and Conditions</h3>
              <p><strong>These Terms might vary between commission type.</strong></p>
              <div>{raw(@terms)}</div>
            </div>
            <Checkbox name={:tos_ok} opts={required: true}>
              <:right>
                I have read and agree to {@studio.name}'s <a href="#">Terms of Service</a>.
              </:right>
            </Checkbox>
            <div class="field">
              <div class="control">
                <Submit
                  class="btn btn-secondary text-center rounded-full py-1 px-5 m-1"
                  label="Submit"
                  opts={disabled: Enum.empty?(@changeset.changes) || !@changeset.valid?}
                />
              </div>
            </div>
          </Form>
        </div>

        <div class="col-span-2">
          <div id="sidebar">
            <div class="block sidebar-box">
              <Card>
                <:header>
                  Choose Offerings
                </:header>
                <div class="content">
                  <div class="tags has-addons">
                    <span class="tag is-medium is-success">
                      $150.00
                    </span>
                    <span class="tag is-medium">
                      Base Price
                    </span>
                  </div>
                  <ul>
                    <li>One Character</li>
                    <li>Full Color</li>
                    <li>Color Background</li>
                  </ul>
                  <hr>
                  <h5>Choose Add-ons</h5>
                  <ul>
                    <li>
                      <div class="tags has-addons">
                        <span class="tag is-medium is-success">
                          +$50.00
                        </span>
                        <span class="tag is-medium">
                          Extra Character
                        </span>
                      </div>
                    </li>
                    <li>
                      <div class="tags has-addons">
                        <span class="tag is-medium is-success">
                          +$50.00
                        </span>
                        <span class="tag is-medium">
                          Extra Character
                        </span>
                      </div>
                    </li>
                    <li>
                      <div class="tags has-addons">
                        <span class="tag is-medium is-success">
                          +$50.00
                        </span>
                        <span class="tag is-medium">
                          Mecha
                        </span>
                      </div>
                    </li>
                    <li>
                      <div class="tags has-addons">
                        <span class="tag is-medium is-success">
                          +$TBD
                        </span>
                        <span class="tag is-medium">
                          Custom Request
                        </span>
                      </div>
                    </li>
                  </ul>
                </div>
              </Card>
            </div>
            <div class="block sidebar-box">
              <Attachments id="commission-attachments" />
            </div>
          </div>
        </div>
      </div>
    </StudioLayout>
    """
  end
end