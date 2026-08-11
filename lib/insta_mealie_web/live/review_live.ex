defmodule InstaMealieWeb.ReviewLive do
  use InstaMealieWeb, :live_view

  alias InstaMealie.Error
  alias InstaMealie.Ingredient
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
          ingredients =
            (job.recipe && job.recipe.ingredients || [])
            |> Enum.filter(&(&1.status == :needs_review))

          {food_candidates, unit_candidates, selected_food, selected_unit, food_terms, unit_terms} =
            Enum.reduce(ingredients, {%{}, %{}, %{}, %{}, %{}, %{}}, fn ing, acc ->
              {fc, uc, sf, su, ft, ut} = acc
              i = ing.index

              food_term = ing.food.name || ing.raw || ""
              unit_term = ing.unit.name || ""

              food_cands = source_food_suggestions(food_term)
              unit_cands = source_unit_suggestions(unit_term)

              {
                Map.put(fc, i, food_cands),
                Map.put(uc, i, unit_cands),
                Map.put(sf, i, initial_food_value(ing, food_cands)),
                Map.put(su, i, initial_unit_value(ing, unit_cands)),
                Map.put(ft, i, ""),
                Map.put(ut, i, "")
              }
            end)

          socket
          |> assign(:job, job)
          |> assign(:not_reviewable, false)
          |> assign(:recipe_name, job.recipe && job.recipe.name)
          |> assign(:ingredients, ingredients)
          |> assign(:food_candidates, food_candidates)
          |> assign(:unit_candidates, unit_candidates)
          |> assign(:food_search_results, %{})
          |> assign(:unit_search_results, %{})
          |> assign(:food_search_terms, food_terms)
          |> assign(:unit_search_terms, unit_terms)
          |> assign(:selected_food, selected_food)
          |> assign(:selected_unit, selected_unit)
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

    review_params = Map.get(params, "review", params)

    resolutions =
      Enum.reduce(ingredients, %{}, fn ing, acc ->
        i = ing.index
        food = String.trim(review_params["food_#{i}"] || "")
        unit = String.trim(review_params["unit_#{i}"] || "")

        changed = food != initial_food(ing) or unit != initial_unit(ing)

        include =
          if ing.status == :needs_review do
            food != "" or unit != ""
          else
            changed
          end

        if include do
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

      {:error, %Error{class: class}} when class in [:network, :auth] ->
        socket = assign(socket, :import_error, class)
        {:noreply, socket}

      {:error, _} ->
        socket = assign(socket, :dead, true)
        {:noreply, socket}
    end
  end

  def handle_event("select-option", params, socket) do
    field = review_param(params, "field")

    with {:ok, index} <- resolve_index(params, field),
         value = review_param(params, "value") do
      socket =
        case field do
          "food" ->
            assign(
              socket,
              :selected_food,
              Map.put(socket.assigns.selected_food, index, value)
            )

          "unit" ->
            assign(
              socket,
              :selected_unit,
              Map.put(socket.assigns.selected_unit, index, value)
            )

          _ ->
            socket
        end

      {:noreply, socket}
    else
      :error -> {:noreply, socket}
    end
  end

  def handle_event("search-food", params, socket) do
    with {:ok, index} <- resolve_index(params, "food"),
         term = review_param(params, "food_#{index}") || "" do
      results = search_foods_safe(term)

      socket =
        socket
        |> assign(:selected_food, Map.put(socket.assigns.selected_food, index, term))
        |> assign(:food_search_terms, Map.put(socket.assigns.food_search_terms, index, term))
        |> assign(
          :food_search_results,
          Map.put(socket.assigns.food_search_results, index, results)
        )

      {:noreply, socket}
    else
      :error -> {:noreply, socket}
    end
  end

  def handle_event("search-unit", params, socket) do
    with {:ok, index} <- resolve_index(params, "unit"),
         term = review_param(params, "unit_#{index}") || "" do
      results = search_units_safe(term)

      socket =
        socket
        |> assign(:selected_unit, Map.put(socket.assigns.selected_unit, index, term))
        |> assign(:unit_search_terms, Map.put(socket.assigns.unit_search_terms, index, term))
        |> assign(
          :unit_search_results,
          Map.put(socket.assigns.unit_search_results, index, results)
        )

      {:noreply, socket}
    else
      :error -> {:noreply, socket}
    end
  end

  def handle_event("retry-review", _params, socket) do
    job = socket.assigns.job

    case Pipeline.retry(job.id) do
      {:ok, _id} ->
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

  defp review_param(params, key, fallback \\ "") do
    nested = get_in(params, ["review", key])

    if is_nil(nested) or nested == "" do
      Map.get(params, key, fallback)
    else
      nested
    end
  end

  defp resolve_index(params, field) when is_map(params) do
    with :error <- resolve_explicit_index(params),
         :error <- resolve_field_key_index(params, field),
         :error <- resolve_target_index(params) do
      :error
    end
  end

  defp resolve_index(_, _), do: :error

  defp resolve_explicit_index(params) when is_map(params) do
    parse_index_value(params["index"] || get_in(params, ["review", "index"]))
  end

  defp resolve_field_key_index(params, field) when is_binary(field) do
    prefix = "#{field}_"
    nested = get_in(params, ["review"]) || %{}

    find_field_key(params, prefix)
    |> Kernel.||(find_field_key(nested, prefix))
    |> case do
      nil -> :error
      key -> parse_numeric_suffix(key, prefix)
    end
  end

  defp resolve_field_key_index(_params, _field), do: :error

  defp find_field_key(map, prefix) when is_map(map) do
    Enum.find(Map.keys(map), fn key -> is_binary(key) && String.starts_with?(key, prefix) end)
  end

  defp find_field_key(_, _), do: nil

  defp parse_numeric_suffix(key, prefix) when is_binary(key) do
    suffix = String.replace_prefix(key, prefix, "")
    parse_index_value(suffix)
  end

  defp resolve_target_index(params) when is_map(params) do
    target = params["_target"] || get_in(params, ["review", "_target"])
    parse_target(target)
  end

  defp parse_target(target) when is_binary(target) do
    target
    |> String.split(~r/[\[\]]/)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> parse_index_from_key()
  end

  defp parse_target(target) when is_list(target) do
    target
    |> List.last()
    |> parse_index_from_key()
  end

  defp parse_target(_), do: :error

  defp parse_index_from_key(key) when is_binary(key) do
    case Regex.run(~r/(\d+)$/, key) do
      [_, num] -> parse_index_value(num)
      _ -> :error
    end
  end

  defp parse_index_from_key(_), do: :error

  defp parse_index_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp parse_index_value(value) when is_integer(value), do: {:ok, value}
  defp parse_index_value(_), do: :error

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
                  <%= for ing <- @ingredients do %>
                    <details
                      class="rounded-2xl border border-base-300 bg-base-100 shadow-sm group"
                      open={ing.status == :needs_review}
                    >
                      <summary class="flex cursor-pointer flex-col gap-3 p-4 list-none sm:flex-row sm:items-start sm:justify-between">
                        <div class="flex-1">
                          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                            Source ingredient
                          </p>
                          <p class="mt-1 font-display text-base font-semibold text-base-content">
                            {ing.raw}
                          </p>
                        </div>
                        <div class="flex-1 sm:text-right">
                          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                            Will import as
                          </p>
                          <div class="mt-1 inline-flex flex-wrap items-baseline gap-x-2 gap-y-1 sm:justify-end">
                            <% parts =
                              preview_parts(
                                ing,
                                @selected_food[ing.index],
                                @selected_unit[ing.index]
                              ) %>
                            <%= if parts.quantity_unit != "" do %>
                              <span class="rounded-md bg-base-300/50 px-1.5 py-0.5 font-mono text-sm text-base-content/70">
                                {parts.quantity_unit}
                              </span>
                            <% end %>
                            <span class="font-display text-sm font-semibold text-base-content">
                              {parts.food}
                            </span>
                            <%= if parts.note != "" do %>
                              <span class="text-sm text-base-content/50">
                                , {parts.note}
                              </span>
                            <% end %>
                            <span class={confidence_badge(Ingredient.confidence_band(ing))}>
                              {confidence_percent_label(Ingredient.confidence_band(ing))}
                            </span>
                          </div>
                        </div>
                        <div class="self-end pt-0 sm:self-auto sm:pt-1">
                          <.icon
                            name="hero-chevron-down"
                            class="size-4 text-base-content/50 transition-transform group-open:rotate-180"
                          />
                        </div>
                      </summary>

                      <div class="border-t border-base-300/50 p-4 space-y-4">
                        <div class="rounded-xl bg-base-200/50 p-3">
                          <div class="flex items-start gap-3">
                            <div class="flex-1">
                              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                                Source ingredient
                              </p>
                              <p class="mt-1 font-display text-base font-semibold text-base-content">
                                {ing.raw}
                              </p>
                            </div>
                            <span class={confidence_badge(Ingredient.confidence_band(ing))}>
                              {confidence_label(Ingredient.confidence_band(ing))}
                            </span>
                          </div>
                        </div>

                        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                          <div class="space-y-2">
                            <div>
                              <label
                                for={"food-#{ing.index}"}
                                class="block text-sm font-medium text-base-content"
                              >
                                Food
                              </label>
                              <p class="mt-1 text-xs text-base-content/60">
                                Choose a Mealie match from the dropdown, or type a custom food.
                              </p>
                            </div>

                            <.combo_box
                              id={"food-#{ing.index}"}
                              field="food"
                              index={ing.index}
                              value={@selected_food[ing.index]}
                              suggested={@food_candidates[ing.index] || []}
                              search_results={@food_search_results[ing.index] || []}
                              query={@food_search_terms[ing.index]}
                              placeholder="Search Mealie foods or enter a custom food…"
                              aria_label="Food used in the recipe"
                              dropdown_aria_label="Show food options"
                              empty_option={false}
                            />
                          </div>

                          <div class="space-y-2">
                            <div>
                              <label
                                for={"unit-#{ing.index}"}
                                class="block text-sm font-medium text-base-content"
                              >
                                Unit
                              </label>
                              <p class="mt-1 text-xs text-base-content/60">
                                Choose a unit from the dropdown, or leave it blank if the ingredient has no unit.
                              </p>
                            </div>

                            <.combo_box
                              id={"unit-#{ing.index}"}
                              field="unit"
                              index={ing.index}
                              value={@selected_unit[ing.index]}
                              suggested={@unit_candidates[ing.index] || []}
                              search_results={@unit_search_results[ing.index] || []}
                              query={@unit_search_terms[ing.index]}
                              placeholder="Search Mealie units or leave blank…"
                              aria_label="Unit used in the recipe"
                              dropdown_aria_label="Show unit options"
                              empty_option={true}
                              empty_label="No unit"
                            />
                          </div>
                        </div>
                      </div>
                    </details>
                  <% end %>

                  <div class="flex flex-col-reverse sm:flex-row items-start sm:items-center justify-between gap-4 pt-2">
                    <div class="flex gap-3">
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
                    <p class="text-sm text-base-content/60">{import_summary(@ingredients)}</p>
                  </div>
                </.form>
              </div>
            <% end %>
          <% end %>
        <% end %>
      <% end %>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ReviewCombo">
      export default {
        mounted() {
          this.open = false;
          this.button = this.el.querySelector("button");

          this.button.addEventListener("click", (e) => {
            e.preventDefault();
            this.open = !this.open;
            this.toggle(this.open);
            if (this.open) this.focusFirst();
          });

          this.el.addEventListener("input", (e) => {
            if (!this.input().contains(e.target)) return;
            this.open = true;
            this.toggle(true);
          });

          this.el.addEventListener("keydown", (e) => {
            const option = e.target.closest('[role="option"]');
            if (option) {
              this.handleOptionKeydown(e, option);
            } else if (e.target === this.input()) {
              this.handleInputKeydown(e);
            }
          });

          this.el.addEventListener("click", (e) => {
            const option = e.target.closest('[role="option"]');
            if (option) this.selectOption(option);
          });

          document.addEventListener("click", (e) => {
            if (!this.el.contains(e.target) && this.open) {
              this.open = false;
              this.toggle(false);
            }
          });
        },

        updated() {
          this.toggle(this.open);
        },

        input() {
          return this.el.querySelector("input");
        },

        list() {
          return this.el.querySelector('[role="listbox"]');
        },

        toggle(open) {
          const list = this.list();
          if (!list) return;
          list.classList.toggle("hidden", !open);
          this.input().setAttribute("aria-expanded", open);
        },

        options() {
          return Array.from(this.list().querySelectorAll('[role="option"]'));
        },

        selectOption(option) {
          const input = this.input();
          input.value = option.getAttribute("phx-value-value") ?? option.textContent.trim();
          this.open = false;
          this.toggle(false);
          input.focus();
        },

        focusFirst() {
          const opts = this.options();
          if (opts.length) opts[0].focus();
        },

        focusLast() {
          const opts = this.options();
          if (opts.length) opts[opts.length - 1].focus();
        },

        handleInputKeydown(e) {
          if (e.key === "ArrowDown") {
            e.preventDefault();
            this.open = true;
            this.toggle(true);
            this.focusFirst();
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            this.open = true;
            this.toggle(true);
            this.focusLast();
          } else if (e.key === "Enter" && this.open) {
            e.preventDefault();
            const first = this.options()[0];
            if (first) first.click();
          } else if (e.key === "Escape" && this.open) {
            e.preventDefault();
            this.open = false;
            this.toggle(false);
            this.input().focus();
          } else if (e.key === "Tab" && this.open) {
            this.open = false;
            this.toggle(false);
          }
        },

        handleOptionKeydown(e, option) {
          const opts = this.options();
          const idx = opts.indexOf(option);

          if (e.key === "ArrowDown") {
            e.preventDefault();
            const next = opts[idx + 1];
            if (next) next.focus();
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            if (idx > 0) {
              opts[idx - 1].focus();
            } else {
              this.open = false;
              this.toggle(false);
              this.input().focus();
            }
          } else if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            option.click();
          } else if (e.key === "Escape") {
            e.preventDefault();
            this.open = false;
            this.toggle(false);
            this.input().focus();
          } else if (e.key === "Tab") {
            e.preventDefault();
            option.click();
          }
        }
      }
    </script>
    """
  end

  defp combo_box(assigns) do
    ~H"""
    <div class="relative" phx-hook=".ReviewCombo" id={"#{@field}-combo-#{@index}"}>
      <div class="relative">
        <input
          id={@id}
          name={"#{@field}_#{@index}"}
          type="text"
          value={@value}
          placeholder={@placeholder}
          autocomplete="off"
          role="combobox"
          aria-expanded="false"
          aria-controls={"#{@field}-list-#{@index}"}
          aria-label={@aria_label}
          phx-change={"search-#{@field}"}
          phx-value-index={@index}
          phx-debounce="300"
          class="w-full rounded-lg border border-base-300 bg-base-100 py-2 pl-3 pr-10 text-sm text-base-content placeholder:text-base-content/40 focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/30"
        />
        <button
          type="button"
          tabindex="-1"
          aria-label={@dropdown_aria_label}
          aria-controls={"#{@field}-list-#{@index}"}
          class="absolute inset-y-0 right-0 flex items-center rounded-r-lg border-l border-base-300 bg-base-100 px-3 text-base-content/60 transition hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-primary/30"
        >
          <.icon name="hero-chevron-down" class="size-4" />
        </button>
      </div>

      <div
        id={"#{@field}-list-#{@index}"}
        role="listbox"
        class="hidden absolute z-10 mt-1 max-h-60 w-full overflow-auto rounded-lg border border-base-300 bg-base-100 py-1 shadow-lg"
      >
        <% suggested = @suggested %>
        <% search_results =
          @search_results |> filter_options(@query) |> Enum.reject(&(&1 in suggested)) %>

        <%= if @empty_option && query_empty?(@query) do %>
          <div
            role="option"
            tabindex="0"
            phx-click="select-option"
            phx-value-field={@field}
            phx-value-index={@index}
            phx-value-value=""
            class="cursor-pointer px-3 py-2 text-sm text-base-content/70 hover:bg-base-200 focus:bg-base-200 focus:outline-none"
          >
            {@empty_label}
          </div>
        <% end %>

        <%= if suggested != [] do %>
          <div role="group" aria-label="Suggested">
            <div class="px-3 py-1 text-xs font-medium uppercase tracking-wide text-base-content/50">
              Suggested
            </div>
            <%= for cand <- suggested do %>
              <div
                role="option"
                tabindex="0"
                phx-click="select-option"
                phx-value-field={@field}
                phx-value-index={@index}
                phx-value-value={cand}
                class="cursor-pointer px-3 py-2 text-sm text-base-content hover:bg-base-200 focus:bg-base-200 focus:outline-none"
              >
                {cand}
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if search_results != [] do %>
          <div role="group" aria-label="Search results">
            <div class="px-3 py-1 text-xs font-medium uppercase tracking-wide text-base-content/50">
              Search results
            </div>
            <%= for cand <- search_results do %>
              <div
                role="option"
                tabindex="0"
                phx-click="select-option"
                phx-value-field={@field}
                phx-value-index={@index}
                phx-value-value={cand}
                class="cursor-pointer px-3 py-2 text-sm text-base-content hover:bg-base-200 focus:bg-base-200 focus:outline-none"
              >
                {cand}
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if no_options?(@empty_option, @query, search_results) do %>
          <div class="px-3 py-2 text-sm text-base-content/50">
            No pantry matches. The current text will be used as a custom value.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp filter_options(items, nil), do: items
  defp filter_options(items, ""), do: items

  defp filter_options(items, query) do
    q = String.downcase(query)

    Enum.filter(items, fn item ->
      String.contains?(String.downcase(item), q)
    end)
  end

  defp query_empty?(nil), do: true
  defp query_empty?(""), do: true
  defp query_empty?(_), do: false

  defp no_options?(empty_option, query, search_results) do
    not empty_option && not query_empty?(query) && search_results == []
  end

  defp source_food_suggestions(term), do: limited_suggestions(term, &search_foods_safe/1, 5)
  defp source_unit_suggestions(term), do: limited_suggestions(term, &search_units_safe/1, 5)

  defp limited_suggestions(term, search_fn, limit) do
    results = search_fn.(term)
    if results == [], do: Enum.take(search_fn.(""), limit), else: Enum.take(results, limit)
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

  defp initial_food_value(ing, cands) do
    cond do
      ing.food.name && ing.food.name in cands -> ing.food.name
      true -> ing.food.name || ing.raw || ""
    end
  end

  defp initial_unit_value(ing, cands) do
    cond do
      ing.unit.name && ing.unit.name in cands -> ing.unit.name
      true -> ing.unit.name || ""
    end
  end

  defp preview_parts(ing, selected_food, selected_unit) do
    food = if selected_food && selected_food != "", do: selected_food, else: "?"
    unit = selected_unit || ""
    note = ing.note || ""

    %{
      quantity_unit: formatted_quantity_unit(ing.quantity, unit),
      food: food,
      note: note
    }
  end

  defp formatted_quantity_unit(_quantity, unit) when unit == "" or unit == nil, do: ""

  defp formatted_quantity_unit(quantity, unit) do
    formatted_quantity = format_quantity(quantity)
    if formatted_quantity != "", do: formatted_quantity <> " " <> unit, else: unit
  end

  defp format_quantity(nil), do: ""
  defp format_quantity(""), do: ""
  defp format_quantity(q) when is_integer(q), do: to_string(q)

  defp format_quantity(q) when is_float(q) do
    if trunc(q) == q, do: to_string(trunc(q)), else: to_string(q)
  end

  defp format_quantity(q), do: to_string(q)

  defp import_summary(ingredients) do
    count = Enum.count(ingredients)
    plural = if count == 1, do: "ingredient", else: "ingredients"
    "#{count} #{plural} to import"
  end

  defp confidence_badge(:high),
    do: "rounded-full bg-success/15 px-2 py-0.5 text-xs font-medium text-success"

  defp confidence_badge(:medium),
    do: "rounded-full bg-warning/15 px-2 py-0.5 text-xs font-medium text-warning"

  defp confidence_badge(:low),
    do: "rounded-full bg-error/15 px-2 py-0.5 text-xs font-medium text-error"

  defp confidence_badge(:unknown),
    do: "rounded-full bg-base-300/30 px-2 py-0.5 text-xs font-medium text-base-content/50"

  defp confidence_label(:high), do: "High"
  defp confidence_label(:medium), do: "Medium"
  defp confidence_label(:low), do: "Low"
  defp confidence_label(:unknown), do: "Unknown"

  defp initial_food(ing), do: ing.food.name || ing.raw || ""
  defp initial_unit(ing), do: ing.unit.name || ""

  defp confidence_percent_label(:high), do: "High confidence"
  defp confidence_percent_label(:medium), do: "Medium confidence"
  defp confidence_percent_label(:low), do: "Low confidence"
  defp confidence_percent_label(:unknown), do: "Unknown confidence"
end
