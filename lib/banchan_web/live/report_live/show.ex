defmodule BanchanWeb.ReportLive.Show do
  @moduledoc """
  Shows report details and allows editing.
  """
  use BanchanWeb, :surface_view

  alias Banchan.Reports
  alias Banchan.Reports.Report

  alias Surface.Components.{Form, LiveRedirect}

  alias BanchanWeb.Components.{Avatar, Button, Layout, Markdown, UserHandle}
  alias BanchanWeb.Components.Form.{MarkdownInput, Select, Submit}

  @impl true
  def handle_params(%{"id" => report_id}, uri, socket) do
    report = Reports.get_report_by_id!(report_id)

    {:noreply,
     socket
     |> assign(
       uri: uri,
       report: report,
       changeset: Report.update_changeset(report, %{})
     )}
  end

  @impl true
  def handle_event("change", %{"report" => report}, socket) do
    changeset =
      socket.assigns.report
      |> Report.update_changeset(report)
      |> Map.put(:action, :update)

    {:noreply, socket |> assign(changeset: changeset)}
  end

  @impl true
  def handle_event("submit", %{"report" => report}, socket) do
    case Reports.update_report(socket.assigns.current_user, socket.assigns.report, report) do
      {:ok, report} ->
        {:noreply,
         socket
         |> assign(
           report: report,
           changeset: Report.update_changeset(report, %{})
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(changeset: changeset)}
    end
  end

  @impl true
  def handle_event("self_assign", _, socket) do
    case Reports.assign_report(
           socket.assigns.current_user,
           socket.assigns.report,
           socket.assigns.current_user
         ) do
      {:ok, report} ->
        {:noreply,
         socket
         |> assign(
           report: report,
           changeset: Report.update_changeset(report, %{})
         )}

      {:error, :not_an_admin} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to perform this action.")
         |> push_redirect(to: Routes.home_path(Endpoint, :index))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to perform this action.")
         |> push_redirect(to: Routes.home_path(Endpoint, :index))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(changeset: changeset)}
    end
  end

  @impl true
  def handle_event("unassign", _, socket) do
    case Reports.assign_report(socket.assigns.current_user, socket.assigns.report, nil) do
      {:ok, report} ->
        {:noreply,
         socket
         |> assign(
           report: report,
           changeset: Report.update_changeset(report, %{})
         )}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to perform this action.")
         |> push_redirect(to: Routes.home_path(Endpoint, :index))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(changeset: changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~F"""
    <Layout uri={@uri} current_user={@current_user} flashes={@flash}>
      <div class="relative">
        <h1 class="text-3xl flex flex-row items-center px-4 sticky top-16 bg-base-100 z-30 pb-2 border-b-2 border-base-content border-opacity-10 opacity-100 items-center">
          <LiveRedirect class="px-2 pb-4" to={Routes.report_index_path(Endpoint, :index)}>
            <i class="fas fa-arrow-left text-2xl" />
          </LiveRedirect>
          <div class="px-2 pb-2 flex flex-row w-full items-center gap-2">
            Viewing Report
            <div class="badge badge-primary badge-xl">{@report.status}</div>
          </div>
        </h1>
        <div class="w-full">
          <div class="max-w-xl w-full h-full mx-auto md:my-4 bg-base-100 flex flex-col">
            <div class="text-xl flex flex-row">
              Reported by
              <Avatar class="mx-2 w-8" user={@current_user} />
              <UserHandle user={@current_user} />
              <div class="mx-2">
                {Timex.format!(@report.inserted_at, "{relative}", :relative)}
              </div>
            </div>
            <div class="flex flex-col md:flex-row gap-2">
              <span class="text-xl font-semibold">URL:</span>
              <LiveRedirect to={@report.uri}>
                <span class="link">
                  {@report.uri}
                </span>
              </LiveRedirect>
            </div>
            <div class="text-xl flex flex-row flex-wrap gap-2 items-center">
              <div class="flex flex-row items-center grow gap-2">
                Assigned to
                {#if @report.investigator}
                  <Avatar class="mx-2 w-8" user={@current_user} />
                  <UserHandle user={@current_user} />
                {#else}
                  <span class="font-semibold">Nobody</span>
                {/if}
              </div>
              {#if is_nil(@report.investigator) || @report.investigator.id != @current_user.id}
                <Button class="btn-link" click="self_assign">
                  Assign to Myself
                </Button>
              {/if}
              {#if @report.investigator}
                <Button class="btn-link" click="unassign">
                  Unassign
                </Button>
              {/if}
            </div>
            <div class="divider" />
            <h2 class="text-xl font-semibold">
              Report
            </h2>
            <Markdown content={@report.message} class="pt-4" />
            <div class="divider" />
            <Form for={@changeset} change="change" submit="submit">
              <Select
                name={:status}
                options={
                  New: :new,
                  Investigating: :investigating,
                  Resolved: :resolved
                }
              />
              <MarkdownInput id="notes-field" name={:notes} />
              <Submit changeset={@changeset} />
            </Form>
          </div>
        </div>
      </div>
    </Layout>
    """
  end
end
