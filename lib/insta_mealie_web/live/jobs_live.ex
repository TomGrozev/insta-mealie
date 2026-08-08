defmodule InstaMealieWeb.JobsLive do
  use InstaMealieWeb, :live_view

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.PubSub

  @topic "jobs"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(PubSub, @topic)

    jobs = Pipeline.list_recent_jobs()

    socket =
      socket
      |> assign(:form, to_form(%{"url" => ""}, as: :job))
      |> assign(:form_error, nil)
      |> stream(:jobs, jobs, reset: true)
      |> assign(:jobs_empty?, jobs == [])

    {:ok, socket}
  end

  @impl true
  def handle_event("create", %{"job" => %{"url" => url}}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, assign(socket, :form_error, "Paste a reel URL to begin.")}
    else
      case Pipeline.create_job(%{url: url}) do
        {:ok, _id} -> {:noreply, assign(socket, :form_error, nil)}
        {:error, _} -> {:noreply, assign(socket, :form_error, "Could not start the job.")}
      end
    end
  end

  @impl true
  def handle_info({:job_updated, %Job{} = job}, socket) do
    socket = stream_insert(socket, :jobs, job)
    {:noreply, assign(socket, :jobs_empty?, false)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold tracking-tight text-base-content">InstaMealie</h1>
          <p class="text-sm text-base-content/70">
            Paste an Instagram reel URL and turn it into a Mealie recipe.
          </p>
        </header>

        <.form for={@form} id="job-form" phx-submit="create" class="flex items-center gap-2">
          <div class="relative flex-1">
            <.input
              field={@form[:url]}
              type="url"
              placeholder="https://instagram.com/reel/..."
              class="w-full rounded-xl border border-base-300 bg-base-100 px-4 py-3 pl-11 text-base-content placeholder:text-base-content/40 focus:border-primary focus:ring-2 focus:ring-primary/30"
            />
            <span class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40">
              <.icon name="hero-link" class="size-5" />
            </span>
          </div>
          <button
            type="submit"
            class="rounded-xl bg-primary px-5 py-3 font-medium text-primary-content transition hover:opacity-90 active:scale-[0.98]"
          >
            Create job
          </button>
        </.form>

        <%= if @form_error do %>
          <p class="text-sm text-error">{@form_error}</p>
        <% end %>

        <section class="space-y-3">
          <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Recent jobs
          </h2>

          <div id="jobs" phx-update="stream" class="space-y-3">
            <div :for={{id, job} <- @streams.jobs} id={id}>
              <.job_card job={job} />
            </div>
          </div>

          <%= if @jobs_empty? do %>
            <p class="rounded-2xl border border-dashed border-base-300 bg-base-100/50 p-6 text-center text-sm text-base-content/50">
              No jobs yet — paste a reel URL above to begin.
            </p>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def job_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="truncate text-sm font-medium text-base-content">
            {@job.url || @job.caption || "Job #{@job.id}"}
          </p>
          <p class="mt-0.5 text-xs text-base-content/50">{verdict_text(@job)}</p>
        </div>

        <%= if @job.state == :succeeded and @job.deep_link do %>
          <a
            id={"deep-link-#{@job.id}"}
            href={@job.deep_link}
            target="_blank"
            rel="noopener noreferrer"
            class="shrink-0 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90"
          >
            Open in Mealie <.icon name="hero-arrow-top-right-on-square" class="inline size-4" />
          </a>
        <% end %>
      </div>

      <div class="mt-3 flex flex-wrap gap-2">
        <%= for stage <- [:fetch, :transcribe, :llm_format, :llm_merge, :mealie_import] do %>
          <span data-stage={stage} class={stage_chip_class(Map.get(@job.stages, stage, :pending))}>
            {stage_label(stage)}
          </span>
        <% end %>
      </div>

      <%= if @job.state == :failed do %>
        <p class="mt-3 rounded-lg bg-error/10 px-3 py-2 text-xs text-error">
          {@job.error_summary}
        </p>
      <% end %>
    </div>
    """
  end

  defp stage_chip_class(:done),
    do: "rounded-full bg-success/15 px-2.5 py-1 text-xs font-medium text-success"

  defp stage_chip_class(:skipped),
    do:
      "rounded-full bg-base-200 px-2.5 py-1 text-xs font-medium text-base-content/50 line-through"

  defp stage_chip_class(:running),
    do: "rounded-full bg-primary/15 px-2.5 py-1 text-xs font-medium text-primary"

  defp stage_chip_class(:failed),
    do: "rounded-full bg-error/15 px-2.5 py-1 text-xs font-medium text-error"

  defp stage_chip_class(:pending),
    do: "rounded-full bg-base-200 px-2.5 py-1 text-xs font-medium text-base-content/40"

  defp stage_label(:fetch), do: "Fetch"
  defp stage_label(:transcribe), do: "Transcribe"
  defp stage_label(:llm_format), do: "Format"
  defp stage_label(:llm_merge), do: "Merge"
  defp stage_label(:mealie_import), do: "Import"

  defp verdict_text(%{state: :succeeded}), do: "Imported to Mealie"
  defp verdict_text(%{state: :failed}), do: "Failed"
  defp verdict_text(%{state: :created}), do: "Queued"
  defp verdict_text(%{state: :caption_pasting}), do: "Awaiting caption"
  defp verdict_text(_), do: "Working…"
end
