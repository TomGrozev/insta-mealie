defmodule InstaMealieWeb.ReviewLive do
  use InstaMealieWeb, :live_view

  alias InstaMealie.Pipeline
  alias InstaMealie.PubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(PubSub, "jobs")

    job = Pipeline.get_job(id)

    socket =
      cond do
        job == nil or job.state != :needs_review ->
          socket
          |> assign(:job, job)
          |> assign(:not_reviewable, true)

        true ->
          ingredients = get_in(job.review, [:ingredients]) || []
          unknown = Enum.filter(ingredients, & &1.unknown)

          {food_candidates, unit_candidates} =
            Enum.reduce(unknown, {%{}, %{}}, fn ing, {fc, uc} ->
              guess = ing.food || ing.raw || ""
              food_cands = search_foods_safe(guess)
              unit_cands = search_units_safe(guess)
              {Map.put(fc, ing.index, food_cands), Map.put(uc, ing.index, unit_cands)}
            end)

          all_foods = search_foods_safe("")
          all_units = search_units_safe("")

          socket
          |> assign(:job, job)
          |> assign(:not_reviewable, false)
          |> assign(:recipe_name, job.recipe["name"])
          |> assign(:ingredients, ingredients)
          |> assign(:food_candidates, food_candidates)
          |> assign(:unit_candidates, unit_candidates)
          |> assign(:all_foods, all_foods)
          |> assign(:all_units, all_units)
          |> assign(:imported, false)
          |> assign(:dead, false)
          |> assign(:import_error, nil)
          |> assign(:deep_link, nil)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("import", params, socket) do
    job = socket.assigns.job
    ingredients = socket.assigns.ingredients
    unknown = Enum.filter(ingredients, & &1.unknown)

    # The form uses as: :review, so real browser submits nest under "review".
    # Fall back to flat params for tests that call handle_event directly.
    review_params = Map.get(params, "review", params)

    resolutions =
      Enum.reduce(unknown, %{}, fn ing, acc ->
        i = ing.index
        selected_food = review_params["food_#{i}"] || ""
        selected_unit = review_params["unit_#{i}"] || ""

        food =
          if selected_food == "__custom__",
            do: String.trim(review_params["custom_food_#{i}"] || ""),
            else: selected_food

        unit =
          if selected_unit == "__custom__",
            do: String.trim(review_params["custom_unit_#{i}"] || ""),
            else: selected_unit

        if food != "" or unit != "" do
          Map.put(acc, i, %{"food" => food, "unit" => unit})
        else
          acc
        end
      end)

    case Pipeline.apply_ingredient_resolutions(job.id, resolutions) do
      {:ok, job} ->
        socket =
          socket
          |> assign(:job, job)
          |> assign(:imported, true)
          |> assign(:deep_link, job.deep_link)

        {:noreply, socket}

      {:error, :validation, _reason} ->
        socket = assign(socket, :dead, true)
        {:noreply, socket}

      {:error, class, _reason} when class in [:network, :auth] ->
        socket = assign(socket, :import_error, class)
        {:noreply, socket}
    end
  end

  def handle_event("search-food", %{"index" => index, "term" => term}, socket) do
    idx = String.to_integer(index)
    candidates = search_foods_safe(term)

    socket =
      socket
      |> assign(:food_candidates, Map.put(socket.assigns.food_candidates, idx, candidates))

    {:noreply, socket}
  end

  def handle_event("search-unit", %{"index" => index, "term" => term}, socket) do
    idx = String.to_integer(index)
    candidates = search_units_safe(term)

    socket =
      socket
      |> assign(:unit_candidates, Map.put(socket.assigns.unit_candidates, idx, candidates))

    {:noreply, socket}
  end

  def handle_event("retry-review", _params, socket) do
    job = socket.assigns.job

    case Pipeline.retry(job.id) do
      {:ok, _id} ->
        # Pipeline.retry may re-fire import inline. Get the updated job.
        updated_job = Pipeline.get_job(job.id)

        socket =
          cond do
            updated_job.state == :succeeded ->
              socket
              |> assign(:job, updated_job)
              |> assign(:imported, true)
              |> assign(:deep_link, updated_job.deep_link)
              |> assign(:import_error, nil)

            updated_job.state == :failed and updated_job.error_class == :validation ->
              socket
              |> assign(:job, updated_job)
              |> assign(:dead, true)
              |> assign(:import_error, nil)

            updated_job.state == :failed ->
              socket
              |> assign(:job, updated_job)
              |> assign(:import_error, updated_job.error_class)

            true ->
              assign(socket, :job, updated_job)
          end

        {:noreply, socket}

      {:error, class, _reason} ->
        socket = assign(socket, :import_error, class)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:job_updated, %InstaMealie.Pipeline.Job{} = job}, socket) do
    socket = assign(socket, :job, job)
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @not_reviewable do %>
        <div class="space-y-4">
          <div class="rounded-2xl border border-base-300 bg-base-100 p-6 text-center">
            <p class="text-base-content/70">Nothing to review.</p>
          </div>
          <.link navigate={~p"/"} class="text-sm text-primary hover:underline">
            ← Back to jobs
          </.link>
        </div>
      <% else %>
        <%= if @imported do %>
          <div class="space-y-4">
            <div class="rounded-2xl border border-success/30 bg-success/5 p-6 text-center">
              <p class="font-display text-lg font-semibold text-success">Recipe imported!</p>
              <%= if @deep_link do %>
                <a
                  href={@deep_link}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="mt-3 inline-block rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content transition hover:opacity-90"
                >
                  Open in Mealie <.icon name="hero-arrow-top-right-on-square" class="inline size-4" />
                </a>
              <% end %>
            </div>
            <.link navigate={~p"/"} class="text-sm text-primary hover:underline">
              ← Back to jobs
            </.link>
          </div>
        <% else %>
          <%= if @dead do %>
            <div class="space-y-4">
              <div class="rounded-2xl border border-error/30 bg-error/5 p-6 text-center">
                <p class="font-display text-lg font-semibold text-error">Import failed</p>
                <p class="mt-1 text-sm text-base-content/70">
                  The recipe was rejected by Mealie. Fix the source and create a new job.
                </p>
              </div>
              <.link navigate={~p"/"} class="text-sm text-primary hover:underline">
                ← Back to jobs
              </.link>
            </div>
          <% else %>
            <%= if @import_error do %>
              <div class="space-y-4">
                <div class="rounded-2xl border border-error/30 bg-error/5 p-6">
                  <p class="font-display text-lg font-semibold text-error">Import error</p>
                  <p class="mt-1 text-sm text-base-content/70">
                    {to_string(@import_error)} error during import. You can retry.
                  </p>
                  <button
                    id="retry-review"
                    type="button"
                    phx-click="retry-review"
                    class="mt-3 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content transition hover:opacity-90 active:scale-[0.98]"
                  >
                    Retry
                  </button>
                </div>
                <.link navigate={~p"/"} class="text-sm text-primary hover:underline">
                  ← Back to jobs
                </.link>
              </div>
            <% else %>
              <div class="space-y-6">
                <div>
                  <h1 class="font-display text-2xl font-semibold text-base-content">
                    Ingredient Review
                  </h1>
                  <p class="mt-1 text-sm text-base-content/60">
                    {@recipe_name} — confirm or correct unknown ingredients before import.
                  </p>
                </div>

                <.form
                  id="review-import-form"
                  phx-submit="import"
                  for={%{}}
                  as={:review}
                  class="space-y-4"
                >
                  <%= for ing <- Enum.filter(@ingredients, & &1.unknown) do %>
                    <div class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm space-y-3">
                      <div class="flex items-center gap-2">
                        <span class="text-sm font-medium text-base-content">{ing.raw}</span>
                        <span class={confidence_badge(ing.food_confidence)}>
                          {confidence_label(ing.food_confidence)}
                        </span>
                      </div>

                      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">Food</label>
                          <div class="space-y-1">
                            <select
                              id={"food-#{ing.index}"}
                              name={"food_#{ing.index}"}
                              phx-hook=".ReviewSelect"
                              data-index={ing.index}
                              data-field="food"
                              class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:border-primary focus:ring-2 focus:ring-primary/30"
                            >
                              <%= if food_cands = @food_candidates[ing.index] do %>
                                <optgroup label="Suggested">
                                  <%= for cand <- food_cands do %>
                                    <option
                                      value={cand}
                                      selected={
                                        not food_has_no_candates?(ing.index, @food_candidates) and
                                          cand == ing.food
                                      }
                                    >
                                      {cand}
                                    </option>
                                  <% end %>
                                </optgroup>
                              <% end %>
                              <optgroup label="All foods">
                                <%= for cand <- @all_foods do %>
                                  <option
                                    value={cand}
                                    selected={
                                      not food_has_no_candates?(ing.index, @food_candidates) and
                                        cand == ing.food
                                    }
                                  >
                                    {cand}
                                  </option>
                                <% end %>
                              </optgroup>
                              <option
                                value="__custom__"
                                selected={food_has_no_candates?(ing.index, @food_candidates)}
                              >
                                ➕ Custom…
                              </option>
                            </select>

                            <input
                              type="text"
                              id={"custom-food-#{ing.index}"}
                              name={"custom_food_#{ing.index}"}
                              value={ing.food || ing.raw || ""}
                              placeholder="Type custom food…"
                              class={[
                                "w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:border-primary focus:ring-2 focus:ring-primary/30",
                                if(food_has_no_candates?(ing.index, @food_candidates),
                                  do: "",
                                  else: "hidden"
                                )
                              ]}
                            />
                          </div>
                        </div>

                        <div>
                          <label class="block text-xs font-medium text-base-content/60 mb-1">Unit</label>
                          <div class="space-y-1">
                            <select
                              id={"unit-#{ing.index}"}
                              name={"unit_#{ing.index}"}
                              phx-hook=".ReviewSelect"
                              data-index={ing.index}
                              data-field="unit"
                              class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:border-primary focus:ring-2 focus:ring-primary/30"
                            >
                              <%= if unit_cands = @unit_candidates[ing.index] do %>
                                <optgroup label="Suggested">
                                  <%= for cand <- unit_cands do %>
                                    <option
                                      value={cand}
                                      selected={
                                        not unit_has_no_candates?(ing.index, @unit_candidates) and
                                          cand == ing.unit
                                      }
                                    >
                                      {cand}
                                    </option>
                                  <% end %>
                                </optgroup>
                              <% end %>
                              <optgroup label="All units">
                                <%= for cand <- @all_units do %>
                                  <option
                                    value={cand}
                                    selected={
                                      not unit_has_no_candates?(ing.index, @unit_candidates) and
                                        cand == ing.unit
                                    }
                                  >
                                    {cand}
                                  </option>
                                <% end %>
                              </optgroup>
                              <option
                                value="__custom__"
                                selected={unit_has_no_candates?(ing.index, @unit_candidates)}
                              >
                                ➕ Custom…
                              </option>
                            </select>

                            <input
                              type="text"
                              id={"custom-unit-#{ing.index}"}
                              name={"custom_unit_#{ing.index}"}
                              value={ing.unit || ""}
                              placeholder="Type custom unit…"
                              class={[
                                "w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:border-primary focus:ring-2 focus:ring-primary/30",
                                if(unit_has_no_candates?(ing.index, @unit_candidates),
                                  do: "",
                                  else: "hidden"
                                )
                              ]}
                            />
                          </div>
                        </div>
                      </div>

                      <div class="text-xs text-base-content/50">
                        → sends:
                        <span id={"preview-#{ing.index}"} class="font-mono">{ing.food || ing.raw ||
                          "?"} {ing.unit ||
                          ""}</span>
                      </div>
                    </div>
                  <% end %>

                  <div class="flex gap-3 pt-2">
                    <button
                      type="submit"
                      id="import-review-submit"
                      class="rounded-xl bg-primary px-5 py-3 font-medium text-primary-content transition hover:opacity-90 active:scale-[0.98]"
                    >
                      Import to Mealie
                    </button>
                    <.link
                      navigate={~p"/"}
                      class="rounded-xl border border-base-300 bg-base-100 px-5 py-3 font-medium text-base-content transition hover:bg-base-200"
                    >
                      Cancel
                    </.link>
                  </div>
                </.form>
              </div>
            <% end %>
          <% end %>
        <% end %>
      <% end %>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ReviewSelect">
      export default {
        mounted() {
          this.el.addEventListener("change", () => {
            const val = this.el.value;
            const idx = this.el.dataset.index;
            const field = this.el.dataset.field;
            const customInput = document.getElementById(`custom-${field}-${idx}`);

            if (val === "__custom__") {
              if (customInput) {
                customInput.classList.remove("hidden");
                customInput.focus();
              }
            } else {
              if (customInput) {
                customInput.classList.add("hidden");
              }
            }

            this.updatePreview(idx);
          });
        },

        updatePreview(idx) {
          const foodSelect = document.getElementById(`food-${idx}`);
          const unitSelect = document.getElementById(`unit-${idx}`);
          const customFood = document.getElementById(`custom-food-${idx}`);
          const customUnit = document.getElementById(`custom-unit-${idx}`);
          const preview = document.getElementById(`preview-${idx}`);

          if (!preview) return;

          const food = foodSelect && foodSelect.value === "__custom__"
            ? (customFood ? customFood.value : "")
            : (foodSelect ? foodSelect.value : "");
          const unit = unitSelect && unitSelect.value === "__custom__"
            ? (customUnit ? customUnit.value : "")
            : (unitSelect ? unitSelect.value : "");

          preview.textContent = `${food || "?"} ${unit || ""}`.trim();
        }
      }
    </script>
    """
  end

  defp search_foods_safe(term) do
    case InstaMealie.Mealie.search_foods(term) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn
          %{"name" => name} -> name
          %{name: name} -> name
          s when is_binary(s) -> s
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp search_units_safe(term) do
    case InstaMealie.Mealie.search_units(term) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn
          %{"name" => name} -> name
          %{name: name} -> name
          s when is_binary(s) -> s
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp food_has_no_candates?(index, food_candidates) do
    case Map.get(food_candidates, index) do
      list when is_list(list) -> list == []
      _ -> false
    end
  end

  defp unit_has_no_candates?(index, unit_candidates) do
    case Map.get(unit_candidates, index) do
      list when is_list(list) -> list == []
      _ -> false
    end
  end

  defp confidence_badge(nil),
    do: "rounded-full bg-warning/15 px-2 py-0.5 text-xs font-medium text-warning"

  defp confidence_badge(c) when c >= 0.85,
    do: "rounded-full bg-success/15 px-2 py-0.5 text-xs font-medium text-success"

  defp confidence_badge(c) when c >= 0.5,
    do: "rounded-full bg-warning/15 px-2 py-0.5 text-xs font-medium text-warning"

  defp confidence_badge(_),
    do: "rounded-full bg-error/15 px-2 py-0.5 text-xs font-medium text-error"

  defp confidence_label(nil), do: "Unknown"
  defp confidence_label(c) when c >= 0.85, do: "High"
  defp confidence_label(c) when c >= 0.5, do: "Medium"
  defp confidence_label(_), do: "Low"
end
