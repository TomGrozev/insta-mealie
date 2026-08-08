defmodule InstaMealie.Pipeline.JobStore do
  @moduledoc "ETS-backed job persistence with rolling TTL and a row cap."
  @table :insta_mealie_jobs

  @doc "Create the ETS table. Safe to call once at boot."
  def create_table do
    if :ets.info(@table) == :undefined do
      :ets.new(
        @table,
        [:set, :public, :named_table, {:read_concurrency, true}, {:write_concurrency, true}]
      )
    else
      @table
    end
  end

  @doc "Persist a job snapshot. Enforces the row cap."
  def put(job) do
    now_ms = System.system_time(:millisecond)
    expires_at = now_ms + ttl_ms()
    :ets.insert(@table, {job.id, job, expires_at, now_ms})
    enforce_cap()
    :ok
  end

  @doc "Read a job snapshot by id."
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, job, _, _}] -> job
      [] -> nil
    end
  end

  @doc "List jobs newest-first by inserted_at."
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, job, _exp, _upd} -> job end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc "Delete a single job."
  def delete(id), do: :ets.delete(@table, id)

  @doc false
  def clear, do: :ets.delete_all_objects(@table)

  @doc "Delete expired rows and trim to the cap. Called by the Sweeper."
  def sweep do
    now_ms = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", now_ms}], [true]}])
    enforce_cap()
    :ok
  end

  @doc false
  def enforce_cap, do: enforce_cap(cap())

  def enforce_cap(cap) when is_integer(cap) do
    size = :ets.info(@table, :size)

    if size > cap do
      excess = size - cap

      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_id, _job, _exp, updated} -> updated end)
      |> Enum.take(excess)
      |> Enum.each(fn {id, _job, _exp, _upd} -> :ets.delete(@table, id) end)
    end

    :ok
  end

  defp ttl_ms do
    Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])[:ttl_ms] || 24 * 60 * 60 * 1000
  end

  defp cap do
    Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])[:cap] || 500
  end
end
