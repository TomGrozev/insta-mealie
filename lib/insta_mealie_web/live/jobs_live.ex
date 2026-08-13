defmodule InstaMealieWeb.JobsLive do
  use InstaMealieWeb, :live_view

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.PubSub

  @topic "jobs"
  @stages_order [:fetch, :llm_format, :scrape_link, :transcribe, :llm_merge, :mealie_import]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(PubSub, @topic)

    jobs = Pipeline.list_recent_jobs()

    socket =
      socket
      |> assign(:form, to_form(%{"url" => ""}, as: :job))
      |> assign(:form_error, nil)
      |> assign(:degraded, InstaMealie.YtDlp.Cli.degraded?())
      |> assign(:caption_editing_id, nil)
      |> assign(:caption_form, to_form(%{"caption" => ""}))
      |> assign(:duplicate_warning, nil)
      |> assign(:last_submitted_url, nil)
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
        {:ok, _id} ->
          {:noreply, assign(socket, form_error: nil, duplicate_warning: nil)}

        {:ok, _id, _position} ->
          {:noreply, assign(socket, form_error: nil, duplicate_warning: nil)}

        {:error, :duplicate_url, existing_id} ->
          warning = build_duplicate_warning(Pipeline.get_job(existing_id))

          {:noreply,
           assign(socket,
             form_error: nil,
             duplicate_warning: warning,
             last_submitted_url: url
           )}

        {:error, _} ->
          {:noreply, assign(socket, :form_error, "Could not start the job.")}
      end
    end
  end

  def handle_event("force-import", _params, socket) do
    case socket.assigns.last_submitted_url do
      nil ->
        {:noreply, assign(socket, :duplicate_warning, nil)}

      url ->
        case Pipeline.create_job(%{url: url, force: true}) do
          {:ok, _id} ->
            {:noreply, assign(socket, form_error: nil, duplicate_warning: nil)}

          {:ok, _id, _position} ->
            {:noreply, assign(socket, form_error: nil, duplicate_warning: nil)}

          {:error, _} ->
            {:noreply, assign(socket, :form_error, "Could not start the job.")}
        end
    end
  end

  def handle_event("create-caption", params, socket) do
    raw = params["caption"]
    caption = if is_map(raw), do: Map.get(raw, "caption", ""), else: raw
    caption = String.trim(caption || "")

    if caption == "" do
      {:noreply, assign(socket, :form_error, "Paste a caption to begin.")}
    else
      case Pipeline.create_job(%{caption: caption}) do
        {:ok, _id} -> {:noreply, assign(socket, :form_error, nil)}
        {:ok, _id, _position} -> {:noreply, assign(socket, :form_error, nil)}
        {:error, _} -> {:noreply, assign(socket, :form_error, "Could not start the job.")}
      end
    end
  end

  def handle_event("retry", %{"job-id" => job_id}, socket) do
    Pipeline.retry(job_id)
    {:noreply, socket}
  end

  def handle_event("paste-caption", %{"job-id" => job_id}, socket) do
    {:noreply, assign(socket, :caption_editing_id, job_id)}
  end

  def handle_event("cancel-paste-caption", %{"job-id" => _job_id}, socket) do
    {:noreply, assign(socket, :caption_editing_id, nil)}
  end

  def handle_event("submit-caption", %{"job-id" => job_id} = params, socket) do
    raw = params["caption"]
    caption = if is_map(raw), do: Map.get(raw, "caption", ""), else: raw
    Pipeline.submit_caption(job_id, String.trim(caption || ""))
    {:noreply, assign(socket, :caption_editing_id, nil)}
  end

  def handle_event("transcribe-anyway", %{"job-id" => job_id}, socket) do
    Pipeline.apply_transcribe_anyway(job_id)
    {:noreply, socket}
  end

  def handle_event("cancel_job", %{"job_id" => job_id}, socket) do
    case Pipeline.cancel_job(job_id) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not cancel job")}
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
      <section class="space-y-6">
        <div class="space-y-2.5">
          <div class="flex items-center gap-2">
            <span class="h-px w-6 bg-primary/60"></span>
            <span class="font-mono text-[10px] uppercase tracking-[0.22em] text-base-content/45">
              Reel → Mealie
            </span>
          </div>
          <h1 class="font-display text-3xl font-semibold tracking-tight text-base-content sm:text-4xl">
            From reel to recipe.
          </h1>
          <p class="max-w-xl text-[15px] leading-relaxed text-base-content/70">
            Paste an Instagram reel URL and InstaMealie pulls the recipe out of it — then sends it to Mealie.
          </p>
        </div>

        <%= if @degraded do %>
          <div class="flex gap-3 rounded-2xl border border-warning/30 bg-warning/10 p-4">
            <span class="mt-0.5 shrink-0 text-warning">
              <.icon name="hero-exclamation-triangle" class="size-5" />
            </span>
            <div class="min-w-0 flex-1 space-y-1 text-sm">
              <p class="font-medium text-warning">Caption-only mode</p>
              <p class="text-base-content/70">
                yt-dlp browser impersonation is unavailable here, so reel fetching is off. Paste a caption to import without the video.
              </p>
            </div>
          </div>

          <.form
            for={@caption_form}
            id="caption-create-form"
            phx-submit="create-caption"
            class="flex flex-col gap-2 sm:flex-row sm:items-start"
          >
            <div class="relative flex-1">
              <.input
                field={@caption_form[:caption]}
                name="caption"
                type="textarea"
                rows="3"
                placeholder="Paste the reel caption…"
                class="w-full rounded-xl border border-base-300 bg-base-200/70 px-4 py-3 pl-12 text-base-content placeholder:text-base-content/40 transition focus:border-primary focus:ring-2 focus:ring-primary/30"
              />
              <span class="pointer-events-none absolute left-3.5 top-3.5 text-primary/60">
                <.icon name="hero-chat-bubble-left-right" class="size-5" />
              </span>
            </div>
            <button
              type="submit"
              class="shrink-0 rounded-xl bg-primary px-5 py-3 font-medium text-primary-content transition hover:opacity-90 active:scale-[0.98]"
            >
              Create job
            </button>
          </.form>

          <%= if @form_error do %>
            <p class="text-sm text-error">{@form_error}</p>
          <% end %>
        <% else %>
          <.form
            for={@form}
            id="job-form"
            phx-submit="create"
            class="flex flex-col gap-2 sm:flex-row sm:items-center"
          >
            <div class="relative flex-1">
              <.input
                field={@form[:url]}
                type="url"
                placeholder="https://instagram.com/reel/..."
                class="w-full rounded-xl border border-base-300 bg-base-200/70 px-4 py-3 pl-12 text-base-content placeholder:text-base-content/40 transition focus:border-primary focus:ring-2 focus:ring-primary/30"
              />
              <span class="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-primary/60">
                <.icon name="hero-link" class="size-5" />
              </span>
            </div>
            <button
              type="submit"
              class="shrink-0 inline-flex items-center justify-center gap-1.5 rounded-xl bg-primary px-5 py-3 font-medium text-primary-content transition hover:opacity-90 active:scale-[0.98]"
            >
              Create job <.icon name="hero-arrow-right" class="size-4 opacity-80" />
            </button>
          </.form>

          <%= if @form_error do %>
            <p class="flex items-center gap-1.5 text-sm text-error">
              <.icon name="hero-exclamation-circle" class="size-4" />
              {@form_error}
            </p>
          <% end %>
        <% end %>

        <%= if @duplicate_warning do %>
          <div class="flex gap-3 rounded-2xl border border-warning/40 bg-warning/10 p-4">
            <span class="mt-0.5 shrink-0 text-warning">
              <.icon name="hero-arrow-path-rounded-square" class="size-5" />
            </span>
            <div class="min-w-0 flex-1 space-y-2">
              <p class="text-sm font-semibold text-warning">
                A job for this URL already exists.
              </p>
              <p class="text-xs text-base-content/60">
                {duplicate_warning_detail(@duplicate_warning)}
              </p>
              <div class="flex flex-wrap gap-2">
                <%= if @duplicate_warning.deep_link do %>
                  <a
                    id="duplicate-deep-link"
                    href={@duplicate_warning.deep_link}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90"
                  >
                    View in Mealie <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                  </a>
                <% end %>
                <button
                  id="force-import"
                  type="button"
                  phx-click="force-import"
                  class="rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content transition hover:bg-base-200 active:scale-[0.98]"
                >
                  Import anyway
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <div class="border-t border-base-300/50 pt-5 sm:pt-6">
          <p class="mb-4 font-mono text-[10px] uppercase tracking-[0.18em] text-base-content/45">
            The pipeline · 6 stages
          </p>
          <.pipeline_strip stages={%{}} ghost={true} show_labels={true} />
        </div>
      </section>

      <section class="space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="font-mono text-[10px] uppercase tracking-[0.22em] text-base-content/50">
            Recent jobs
          </h2>
        </div>

        <div id="jobs" phx-update="stream" class="space-y-3">
          <div :for={{id, job} <- @streams.jobs} id={id}>
            <.job_card
              job={job}
              caption_form={@caption_form}
              caption_editing_id={@caption_editing_id}
            />
          </div>
        </div>

        <%= if @jobs_empty? do %>
          <div class="flex flex-col items-center gap-2 rounded-2xl border border-dashed border-base-300/80 bg-base-200/30 px-6 py-10 text-center">
            <span class="flex size-10 items-center justify-center rounded-full bg-primary/10 text-primary/70">
              <.icon name="hero-camera" class="size-5" />
            </span>
            <p class="text-sm font-medium text-base-content/70">No jobs yet</p>
            <p class="max-w-xs text-xs text-base-content/50">
              Paste a reel URL above and InstaMealie will pull the recipe out of it.
            </p>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  attr :stages, :map, default: %{}
  attr :ghost, :boolean, default: false
  attr :show_labels, :boolean, default: true

  def pipeline_strip(assigns) do
    stages_order = @stages_order

    stages_with_status =
      Enum.map(stages_order, fn stage ->
        status = if assigns.ghost, do: :ghost, else: Map.get(assigns.stages, stage, :pending)
        {stage, status}
      end)

    assigns =
      assigns
      |> assign(:stages_order, stages_order)
      |> assign(:stages_with_status, stages_with_status)

    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-center">
        <%= for {{stage, status}, idx} <- Enum.with_index(@stages_with_status) do %>
          <div
            data-stage={stage}
            class={node_classes(status)}
            title={stage_label(stage)}
            aria-label={stage_label(stage)}
          >
            <%= cond do %>
              <% status == :done -> %>
                <.icon name="hero-check" class="size-3.5" />
              <% status == :running -> %>
                <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" />
              <% status == :failed -> %>
                <.icon name="hero-x-mark" class="size-3.5" />
              <% status == :skipped -> %>
                <.icon name="hero-minus" class="size-3.5" />
              <% status == :unresolved -> %>
                <.icon name="hero-question-mark-circle" class="size-3.5" />
              <% true -> %>
                <span class="size-2 rounded-full bg-current"></span>
            <% end %>
          </div>
          <%= if idx < length(@stages_order) - 1 do %>
            <div class={connector_classes(status)} />
          <% end %>
        <% end %>
      </div>
      <%= if @show_labels do %>
        <div class="flex">
          <%= for {{stage, status}, idx} <- Enum.with_index(@stages_with_status) do %>
            <div class={[
              "flex-1 text-center font-mono text-[10px] uppercase tracking-wide text-base-content/45",
              status == :skipped && "line-through opacity-60"
            ]}>
              {stage_label(stage)}
            </div>
            <%= if idx < length(@stages_order) - 1 do %>
              <div class="flex-1"></div>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def job_card(assigns) do
    ~H"""
    <% actions = Pipeline.available_actions(@job) %>
    <div class={[
      "group relative rounded-2xl border bg-base-100/60 p-4 shadow-sm transition hover:bg-base-100",
      card_border_classes(@job)
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="truncate font-display text-base font-semibold tracking-tight text-base-content">
            {job_title(@job)}
          </p>
          <p class={["mt-1 flex items-center gap-1.5 text-xs", verdict_text_classes(@job)]}>
            <span class="size-1.5 rounded-full bg-current"></span>
            {verdict_text(@job)}
          </p>
          <%= if missing_instructions?(@job) do %>
            <span
              class="mt-1.5 inline-flex items-center gap-1 rounded-md border border-warning/30 bg-warning/10 px-1.5 py-0.5 text-[11px] font-medium text-warning/85"
              title="Recipe was imported, but it has no cooking instructions — you may want to add them in Mealie."
            >
              <.icon name="hero-exclamation-triangle" class="size-3" /> No instructions found
            </span>
          <% end %>
        </div>

        <%= if @job.state == :succeeded and @job.deep_link do %>
          <a
            id={"deep-link-#{@job.id}"}
            href={@job.deep_link}
            target="_blank"
            rel="noopener noreferrer"
            class="shrink-0 inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90"
          >
            Open in Mealie <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
        <% end %>

        <%= if @job.state == :needs_review do %>
          <.link
            navigate={~p"/jobs/#{@job.id}/review"}
            id={"review-#{@job.id}"}
            class="shrink-0 inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90"
          >
            Review ingredients <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        <% end %>
      </div>

      <div class="mt-3.5">
        <.pipeline_strip stages={@job.stages} />
      </div>

      <%= if :cancel in actions do %>
        <div class="mt-3 flex justify-end">
          <button
            id={"cancel-#{@job.id}"}
            type="button"
            phx-click="cancel_job"
            phx-value-job_id={@job.id}
            class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-error transition hover:bg-error/10 active:scale-[0.98]"
          >
            <.icon name="hero-x-mark" class="size-4" /> Cancel
          </button>
        </div>
      <% end %>

      <%= if @job.state == :failed do %>
        <div class="mt-4 border-t border-base-300/40 pt-3">
          <div class={[
            "flex w-full items-center justify-between gap-2 rounded-lg px-3 py-2.5",
            banner_classes(@job)
          ]}>
            <span class="flex items-center gap-1.5 text-sm font-semibold">
              <.icon name="hero-exclamation-circle" class="size-4" />
              {stage_label(@job.error_stage)} failed
            </span>
            <span class="flex items-center gap-2">
              <span class="rounded-full bg-base-100/70 px-2 py-0.5 font-mono text-[11px] font-semibold uppercase tracking-wide text-base-content/70">
                {to_string(@job.error_class)}
              </span>
              <span class="group relative inline-flex">
                <button
                  type="button"
                  aria-label={"Show diagnostics for #{stage_label(@job.error_stage)}"}
                  class="rounded p-0.5 text-base-content/60 transition hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-primary"
                >
                  <.icon name="hero-information-circle" class="size-4" />
                </button>
                <span
                  id={"diagnostics-#{@job.id}"}
                  role="tooltip"
                  class="pointer-events-none absolute right-0 top-6 z-10 hidden w-64 rounded-lg border border-base-300 bg-base-100 p-3 text-left text-xs leading-relaxed text-base-content/80 shadow-lg group-hover:block group-focus-within:block"
                >
                  <span class="font-medium">Class:</span> {to_string(@job.error_class)}<br />
                  <span class="font-medium">Raw diagnostics:</span> {raw_diagnostics(@job)}
                </span>
              </span>
            </span>
          </div>

          <%= if Pipeline.dead?(@job) do %>
            <p class="mt-2 text-xs text-base-content/50">
              This job is dead — the recipe was rejected by Mealie. Fix the source and create a new job.
            </p>
          <% else %>
            <p class="mt-2 text-xs text-base-content/60">{cta_explainer(@job, actions)}</p>

            <div class="mt-2.5 flex flex-wrap gap-2">
              <%= if :retry in actions do %>
                <button
                  id={"retry-#{@job.id}"}
                  type="button"
                  phx-click="retry"
                  phx-value-job-id={@job.id}
                  class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90 active:scale-[0.98]"
                >
                  <.icon name="hero-arrow-path" class="size-4" />
                  Retry ({Pipeline.retries_left(@job)} left)
                </button>
              <% end %>

              <%= if :paste_caption in actions do %>
                <button
                  id={"paste-caption-#{@job.id}"}
                  type="button"
                  phx-click="paste-caption"
                  phx-value-job-id={@job.id}
                  class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content transition hover:bg-base-200 active:scale-[0.98]"
                >
                  <.icon name="hero-clipboard-document" class="size-4" /> Paste caption
                </button>
              <% end %>

              <%= if :transcribe_anyway in actions do %>
                <button
                  id={"transcribe-anyway-#{@job.id}"}
                  type="button"
                  phx-click="transcribe-anyway"
                  phx-value-job-id={@job.id}
                  class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content transition hover:bg-base-200 active:scale-[0.98]"
                >
                  <.icon name="hero-document-text" class="size-4" />
                  {transcribe_cta_label(@job)}
                </button>
              <% end %>
            </div>

            <%= if @caption_editing_id == @job.id do %>
              <.form
                for={@caption_form}
                id={"paste-caption-form-#{@job.id}"}
                phx-submit="submit-caption"
                phx-value-job-id={@job.id}
                class="mt-2 rounded-lg border border-base-300/60 bg-base-200/40 p-3"
              >
                <.input
                  field={@caption_form[:caption]}
                  name="caption"
                  type="textarea"
                  rows="3"
                  placeholder="Paste the reel caption…"
                  class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content placeholder:text-base-content/40 focus:border-primary focus:ring-2 focus:ring-primary/30"
                />
                <div class="mt-2 flex gap-2">
                  <button
                    type="submit"
                    class="rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90"
                  >
                    Submit caption
                  </button>
                  <button
                    type="button"
                    phx-click="cancel-paste-caption"
                    phx-value-job-id={@job.id}
                    class="rounded-lg border border-base-300 px-3 py-1.5 text-sm text-base-content transition hover:bg-base-200"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---- CTA matrix (per T5 / decision #18, Variant B) ----
  # The CTA logic now lives in `InstaMealie.Pipeline.available_actions/1` —
  # this module just renders the actions it returns. The remaining helpers
  # here are pure presentation: copy and banner styling.

  defp transcribe_cta_label(%{error_stage: :llm_merge}), do: "Import caption-only"
  defp transcribe_cta_label(_), do: "Transcribe-anyway"

  defp raw_diagnostics(job), do: to_string(job.error_summary || "")

  defp banner_classes(job) do
    if Pipeline.dead?(job) do
      "bg-base-200 text-base-content/60"
    else
      "bg-error/10 text-error"
    end
  end

  # Per-card presentation helpers — pure color/skin mapping from job state.

  defp card_border_classes(%{state: :needs_review}),
    do: "border-primary/40 hover:border-primary/60"

  defp card_border_classes(%{state: :succeeded}), do: "border-success/40 hover:border-success/60"

  defp card_border_classes(%{state: :failed} = job) do
    if Pipeline.dead?(job),
      do: "border-base-300/70",
      else: "border-error/40 hover:border-error/60"
  end

  defp card_border_classes(_), do: "border-base-300/70 hover:border-base-300"

  defp verdict_text_classes(%{state: :succeeded}), do: "text-success/80"
  defp verdict_text_classes(%{state: :needs_review}), do: "text-primary/80"

  defp verdict_text_classes(%{state: :failed} = job) do
    if Pipeline.dead?(job), do: "text-base-content/45", else: "text-error/85"
  end

  defp verdict_text_classes(_), do: "text-base-content/55"

  defp cta_explainer(job, actions) do
    case job.error_stage do
      :transcribe ->
        "The job will continue with the caption-only recipe from routing, skipping the failed audio"

      :llm_merge ->
        "Caption alone has a complete recipe — you can import without the audio"

      :fetch ->
        if :retry in actions do
          "Fetch failed. Retry, or paste the caption to continue without the reel."
        else
          "Fetch is blocked in this environment. Paste the caption to continue without the reel."
        end

      :llm_format ->
        if job.error_class == :incomplete_caption do
          "The pasted caption doesn't contain a complete recipe, and there's no audio to transcribe. Try a fuller caption."
        else
          "Recipe formatting failed. Retry to try again."
        end

      :mealie_import ->
        "The recipe could not be imported. Retry the import."

      _ ->
        ""
    end
  end

  # ---- Pipeline strip helpers ----

  defp node_classes(:done),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-primary text-primary-content"

  defp node_classes(:running),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary ring-2 ring-primary/60"

  defp node_classes(:failed),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-error text-error-content"

  defp node_classes(:skipped),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full border-2 border-dashed border-base-content/30 bg-base-200/70 text-base-content/55"

  defp node_classes(:unresolved),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full border-2 border-dashed border-warning/50 bg-warning/15 text-warning"

  defp node_classes(:ghost),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300/70 text-base-content/40"

  defp node_classes(_),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300 text-base-content/40"

  defp connector_classes(:done), do: "h-0.5 flex-1 rounded-full bg-primary"
  defp connector_classes(:skipped), do: "h-0.5 flex-1 rounded-full bg-primary"
  defp connector_classes(:unresolved), do: "h-0.5 flex-1 rounded-full bg-primary"
  defp connector_classes(:ghost), do: "h-0.5 flex-1 rounded-full bg-base-300/70"
  defp connector_classes(_), do: "h-0.5 flex-1 rounded-full bg-base-300"

  defp stage_label(:fetch), do: "Fetch"
  defp stage_label(:transcribe), do: "Transcribe"
  defp stage_label(:llm_format), do: "Format"
  defp stage_label(:scrape_link), do: "Scrape link"
  defp stage_label(:llm_merge), do: "Merge"
  defp stage_label(:mealie_import), do: "Import"

  defp verdict_text(%{state: :succeeded}), do: "Imported to Mealie"
  defp verdict_text(%{state: :needs_review}), do: "Needs ingredient review"
  defp verdict_text(%{state: :failed}), do: "Failed"
  defp verdict_text(%{mode: :skip_audio}), do: "Importing caption-only recipe…"
  defp verdict_text(%{state: :created}), do: "Queued"
  defp verdict_text(%{state: :caption_pasting}), do: "Awaiting caption"
  defp verdict_text(_), do: "Working…"

  # Surface a soft warning on terminal jobs whose recipe extracted without
  # cooking instructions. Informational only — does not gate the CTAs above.
  defp missing_instructions?(%{state: state, recipe: %{instructions: instructions}})
       when state in [:succeeded, :needs_review] and (is_nil(instructions) or instructions == []) do
    true
  end

  defp missing_instructions?(_), do: false

  # Prefer the recipe name once one is available (caption extraction / LLM
  # merge may set it before the import completes), falling back to the raw
  # URL, then the pasted caption, then a "Job N" placeholder when nothing
  # is set yet.
  defp job_title(%{recipe: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp job_title(%{url: url}) when is_binary(url) and url != "", do: url
  defp job_title(%{caption: caption}) when is_binary(caption) and caption != "", do: caption
  defp job_title(%{id: id}), do: "Job #{id}"

  # ---- Duplicate URL warning ----

  # Build the warning payload shown when a freshly-submitted URL already maps
  # to a non-failed, non-cancelled job. If the existing job succeeded we
  # surface its Mealie deep link; otherwise the user can still see the row in
  # the recent jobs list below.
  defp build_duplicate_warning(%{state: :succeeded, deep_link: deep_link} = job)
       when is_binary(deep_link),
       do: %{id: job.id, deep_link: deep_link, state: :succeeded}

  defp build_duplicate_warning(job) do
    %{id: job.id, deep_link: nil, state: job.state}
  end

  defp duplicate_warning_detail(%{state: :succeeded}) do
    "The previous job for this URL is already in Mealie. Open it, or import again anyway."
  end

  defp duplicate_warning_detail(%{state: state}) do
    "The previous job is still #{state_label(state)}. Importing will create a second job."
  end

  defp state_label(:queued), do: "queued"
  defp state_label(:created), do: "starting"
  defp state_label(:needs_review), do: "waiting for ingredient review"

  defp state_label(state) when is_atom(state),
    do: state |> to_string() |> String.replace("_", " ")

  defp state_label(_), do: "in progress"
end
