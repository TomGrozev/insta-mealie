defmodule InstaMealieWeb.JobsLive do
  use InstaMealieWeb, :live_view

  alias InstaMealie.Pipeline
  alias InstaMealie.Pipeline.Job
  alias InstaMealie.PubSub

  @topic "jobs"
  @retry_cap 2
  @stages_order [:fetch, :transcribe, :llm_format, :llm_merge, :mealie_import]

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
        {:ok, _id, _position} -> {:noreply, assign(socket, :form_error, nil)}
        {:error, _} -> {:noreply, assign(socket, :form_error, "Could not start the job.")}
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
      <section class="space-y-5">
        <div class="space-y-2">
          <h1 class="font-display text-3xl font-semibold tracking-tight text-base-content sm:text-4xl">
            From reel to recipe.
          </h1>
          <p class="max-w-xl text-base-content/70">
            Paste an Instagram reel and InstaMealie pulls the recipe out of the video — then sends it to Mealie.
          </p>
        </div>

        <%= if @degraded do %>
          <div class="rounded-2xl border border-warning/30 bg-warning/10 p-4 text-sm">
            <p class="font-medium text-warning">Caption-only mode</p>
            <p class="mt-1 text-base-content/70">
              yt-dlp browser impersonation is unavailable here, so reel fetching is off. Paste a caption to import without the video.
            </p>
          </div>

          <.form
            for={@caption_form}
            id="caption-create-form"
            phx-submit="create-caption"
            class="flex flex-col gap-2 sm:flex-row sm:items-start"
          >
            <.input
              field={@caption_form[:caption]}
              name="caption"
              type="textarea"
              rows="3"
              placeholder="Paste the reel caption…"
              class="w-full rounded-xl border border-base-300 bg-base-200 px-4 py-3 text-base-content placeholder:text-base-content/40 focus:border-primary focus:ring-2 focus:ring-primary/30"
            />
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
                class="w-full rounded-xl border border-base-300 bg-base-200 px-4 py-3 pl-11 text-base-content placeholder:text-base-content/40 focus:border-primary focus:ring-2 focus:ring-primary/30"
              />
              <span class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40">
                <.icon name="hero-link" class="size-5" />
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
        <% end %>

        <div class="rounded-2xl border border-base-300/60 bg-base-200/40 p-4">
          <p class="mb-3 text-xs font-medium uppercase tracking-wider text-base-content/45">
            The pipeline
          </p>
          <.pipeline_strip stages={%{}} ghost={true} />
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Recent jobs
        </h2>

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
          <p class="rounded-2xl border border-dashed border-base-300 bg-base-200/30 p-6 text-center text-sm text-base-content/50">
            No jobs yet — paste a reel URL above to begin.
          </p>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  attr :stages, :map, default: %{}
  attr :ghost, :boolean, default: false

  def pipeline_strip(assigns) do
    assigns = assign(assigns, :stages_order, @stages_order)

    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-center">
        <%= for {stage, idx} <- Enum.with_index(@stages_order) do %>
          <% status = if @ghost, do: :ghost, else: Map.get(@stages, stage, :pending) %>
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
              <% true -> %>
                <span class="size-2 rounded-full bg-current"></span>
            <% end %>
          </div>
          <%= if idx < length(@stages_order) - 1 do %>
            <div class={connector_classes(status)} />
          <% end %>
        <% end %>
      </div>
      <div class="flex">
        <%= for {stage, idx} <- Enum.with_index(@stages_order) do %>
          <div class="flex-1 text-center text-[10px] font-medium uppercase tracking-wide text-base-content/45">
            {stage_label(stage)}
          </div>
          <%= if idx < length(@stages_order) - 1 do %>
            <div class="flex-1"></div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  def job_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300/70 bg-base-200/50 p-4 shadow-sm transition hover:border-base-300">
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

        <%= if @job.state == :needs_review do %>
          <.link
            navigate={~p"/jobs/#{@job.id}/review"}
            id={"review-#{@job.id}"}
            class="shrink-0 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90"
          >
            Review ingredients
          </.link>
        <% end %>
      </div>

      <div class="mt-3">
        <.pipeline_strip stages={@job.stages} />
      </div>

      <%= if @job.state not in [:succeeded, :failed, :cancelled, :queued] do %>
        <div class="mt-2 flex justify-end">
          <button
            id={"cancel-#{@job.id}"}
            type="button"
            phx-click="cancel_job"
            phx-value-job_id={@job.id}
            class="rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-error transition hover:bg-error/10 active:scale-[0.98]"
          >
            Cancel
          </button>
        </div>
      <% end %>

      <%= if @job.state == :failed do %>
        <div class="mt-3">
          <div class={[
            "flex w-full items-center justify-between gap-2 rounded-lg px-3 py-2",
            banner_classes(@job)
          ]}>
            <span class="text-sm font-semibold">{stage_label(@job.error_stage)} failed</span>
            <span class="flex items-center gap-2">
              <span class="rounded-full bg-base-100/70 px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide text-base-content/70">
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

          <%= if dead_row?(@job) do %>
            <p class="mt-2 text-xs text-base-content/50">
              This job is dead — the recipe was rejected by Mealie. Fix the source and create a new job.
            </p>
          <% else %>
            <p class="mt-2 text-xs text-base-content/60">{cta_explainer(@job)}</p>

            <div class="mt-2 flex flex-wrap gap-2">
              <%= if show_retry?(@job) do %>
                <button
                  id={"retry-#{@job.id}"}
                  type="button"
                  phx-click="retry"
                  phx-value-job-id={@job.id}
                  class="rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition hover:opacity-90 active:scale-[0.98]"
                >
                  Retry ({per_stage_retries_left(@job)} left)
                </button>
              <% end %>

              <%= if show_paste_caption?(@job) do %>
                <button
                  id={"paste-caption-#{@job.id}"}
                  type="button"
                  phx-click="paste-caption"
                  phx-value-job-id={@job.id}
                  class="rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content transition hover:bg-base-200 active:scale-[0.98]"
                >
                  Paste caption
                </button>
              <% end %>

              <%= if show_transcribe_anyway?(@job) do %>
                <button
                  id={"transcribe-anyway-#{@job.id}"}
                  type="button"
                  phx-click="transcribe-anyway"
                  phx-value-job-id={@job.id}
                  class="rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content transition hover:bg-base-200 active:scale-[0.98]"
                >
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
                class="mt-2"
              >
                <.input
                  field={@caption_form[:caption]}
                  name="caption"
                  type="textarea"
                  rows="3"
                  placeholder="Paste the reel caption…"
                  class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content placeholder:text-base-content/40 focus:border-primary focus:ring-2 focus:ring-primary/30"
                />
                <div class="mt-1 flex gap-2">
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

  defp retryable_stage?(job) do
    case {job.error_stage, job.error_class} do
      {:mealie_import, :validation} -> false
      {:fetch, :ip_banned} -> false
      {:llm_format, :incomplete_caption} -> false
      {:mealie_import, class} -> class in [:network, :auth, :api_error]
      {stage, _class} when stage in [:fetch, :transcribe, :llm_format, :llm_merge] -> true
      _ -> false
    end
  end

  defp per_stage_retries_left(job) do
    @retry_cap - Map.get(job.retry_count, job.error_stage, 0)
  end

  defp show_retry?(job), do: retryable_stage?(job) and per_stage_retries_left(job) > 0

  defp show_paste_caption?(job), do: job.error_stage == :fetch

  defp show_transcribe_anyway?(job),
    do: job.error_stage in [:transcribe, :llm_merge] and job.mode == :url

  defp dead_row?(job), do: job.error_stage == :mealie_import and job.error_class == :validation

  defp transcribe_cta_label(%{error_stage: :llm_merge}), do: "Import caption-only"
  defp transcribe_cta_label(_), do: "Transcribe-anyway"

  defp raw_diagnostics(job), do: to_string(job.error_summary || "")

  defp banner_classes(job) do
    if dead_row?(job) do
      "bg-base-200 text-base-content/60"
    else
      "bg-error/10 text-error"
    end
  end

  defp cta_explainer(job) do
    case job.error_stage do
      :transcribe ->
        "The job will continue with the caption-only recipe from routing, skipping the failed audio"

      :llm_merge ->
        "Caption alone has a complete recipe — you can import without the audio"

      :fetch ->
        if show_retry?(job) do
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
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300 text-base-content/40"

  defp node_classes(:ghost),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300/70 text-base-content/40"

  defp node_classes(_),
    do:
      "flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300 text-base-content/40"

  defp connector_classes(:done), do: "h-0.5 flex-1 rounded-full bg-primary"
  defp connector_classes(:ghost), do: "h-0.5 flex-1 rounded-full bg-base-300/70"
  defp connector_classes(_), do: "h-0.5 flex-1 rounded-full bg-base-300"

  defp stage_label(:fetch), do: "Fetch"
  defp stage_label(:transcribe), do: "Transcribe"
  defp stage_label(:llm_format), do: "Format"
  defp stage_label(:llm_merge), do: "Merge"
  defp stage_label(:mealie_import), do: "Import"

  defp verdict_text(%{state: :succeeded}), do: "Imported to Mealie"
  defp verdict_text(%{state: :needs_review}), do: "Needs ingredient review"
  defp verdict_text(%{state: :failed}), do: "Failed"
  defp verdict_text(%{mode: :skip_audio}), do: "Importing caption-only recipe…"
  defp verdict_text(%{state: :created}), do: "Queued"
  defp verdict_text(%{state: :caption_pasting}), do: "Awaiting caption"
  defp verdict_text(_), do: "Working…"
end
