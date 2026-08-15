defmodule InstaMealie.PipelineJobStoreTest do
  @moduledoc """
  Unit tests for `InstaMealie.Pipeline.JobStore` covering edge cases not
  exercised by the happy-path `describe "JobStore"` block in
  `test/insta_mealie/pipeline_test.exs` (lines ~90-126), which only covers
  a single expired row swept away and a 5->3 cap trim.

  Uses `InstaMealie.TestCase` so the `JobStore`/`JobAdmission` tables are
  cleared per test and `async: false` is enforced (the table is process-
  global, so parallel tests would race on `clear/0` and on config-driven
  `ttl_ms`/`cap` overrides below).
  """
  use InstaMealie.TestCase

  alias InstaMealie.Pipeline.Job
  alias InstaMealie.Pipeline.JobStore

  # Build a minimal Job struct. Only the fields JobStore inspects/preserves
  # (`id`, `inserted_at`) need realistic values; the rest are defaults.
  defp build_job(id, overrides \\ []) do
    now = DateTime.utc_now()

    base = %Job{
      id: id,
      state: :created,
      stages: %{},
      inserted_at: now,
      updated_at: now
    }

    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  describe "create_table/0" do
    test "is idempotent — returns the table reference when the table already exists" do
      # The Sweeper already creates the table at app boot, so by the time
      # this test runs the table exists. create_table/0 must return the
      # same atom reference without raising — both on the first and every
      # subsequent call.
      assert JobStore.create_table() == :insta_mealie_jobs
      assert JobStore.create_table() == :insta_mealie_jobs
      assert :ets.info(:insta_mealie_jobs) != :undefined
    end
  end

  describe "put/1 + get/1" do
    test "round-trip returns the stored job" do
      job = build_job("rt1")

      assert :ok = JobStore.put(job)
      assert %Job{id: "rt1", state: :created} = JobStore.get("rt1")
    end

    test "get/1 returns nil for an unknown id" do
      assert JobStore.get("never-inserted") == nil
    end

    test "stores expires_at = now + ttl_ms (the value from app env)" do
      ttl =
        Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])[:ttl_ms] ||
          24 * 60 * 60 * 1000

      assert :ok = JobStore.put(build_job("ttl_calc"))

      # Row layout is `{id, job, expires_at, now_ms}` per the `put/1`
      # `:ets.insert` call in `lib/insta_mealie/pipeline/job_store.ex`.
      [{_id, _job, expires_at, stored_now}] = :ets.lookup(:insta_mealie_jobs, "ttl_calc")
      assert expires_at - stored_now == ttl
    end

    test "put/1 with the same job.id overwrites the row and refreshes the TTL" do
      job1 = build_job("dup", state: :created)
      assert :ok = JobStore.put(job1)

      [{_id, _job, exp1, stored_now1}] = :ets.lookup(:insta_mealie_jobs, "dup")

      # Sleep so the second put's stored_now is strictly greater than the
      # first — otherwise the monotonicity assertion below is meaningless.
      Process.sleep(2)

      job2 = build_job("dup", state: :succeeded)
      assert :ok = JobStore.put(job2)

      # `:set` table — same id overwrites, no duplicate row.
      assert length(JobStore.list()) == 1

      # Latest data wins.
      assert %Job{id: "dup", state: :succeeded} = JobStore.get("dup")

      [{_id, _job, exp2, stored_now2}] = :ets.lookup(:insta_mealie_jobs, "dup")

      # Row was rewritten: stored_now moved forward AND the new expiry is
      # anchored at the new "now", not the old one (so the TTL window
      # restarted, not preserved).
      assert stored_now2 > stored_now1
      assert exp2 > exp1
    end
  end

  describe "list/0" do
    test "returns jobs sorted by inserted_at descending" do
      base = DateTime.utc_now()

      for i <- 1..3 do
        JobStore.put(build_job("ord#{i}", inserted_at: DateTime.add(base, i, :second)))
      end

      ids = JobStore.list() |> Enum.map(& &1.id)
      assert ids == ["ord3", "ord2", "ord1"]
    end
  end

  describe "sweep/0" do
    test "deletes only expired rows when the table contains a mix of expired and valid ones" do
      # Valid row via put/1 (gets the default 24h TTL).
      :ok = JobStore.put(build_job("sweep_valid"))

      # Two expired rows inserted directly with an explicit past expires_at,
      # mirroring the existing happy-path sweep test in pipeline_test.exs.
      past_exp = System.system_time(:millisecond) - 60_000
      past_upd = System.system_time(:millisecond) - 60_000

      for id <- ["sweep_exp_a", "sweep_exp_b"] do
        :ets.insert(:insta_mealie_jobs, {id, build_job(id), past_exp, past_upd})
      end

      assert length(JobStore.list()) == 3
      assert :ok = JobStore.sweep()

      ids = JobStore.list() |> Enum.map(& &1.id)
      assert ids == ["sweep_valid"]
      refute "sweep_exp_a" in ids
      refute "sweep_exp_b" in ids
    end
  end

  describe "enforce_cap/1 boundary" do
    test "is a no-op when size == cap" do
      base = DateTime.utc_now()

      for i <- 1..3 do
        JobStore.put(build_job("cap_eq_#{i}", inserted_at: DateTime.add(base, i, :second)))
        # Keep the row's "updated" timestamps distinct so enforce_cap's
        # internal sort_by is deterministic if we extend the test below.
        Process.sleep(2)
      end

      assert length(JobStore.list()) == 3
      assert :ok = JobStore.enforce_cap(3)
      assert length(JobStore.list()) == 3
    end

    test "deletes exactly one oldest row when size == cap + 1" do
      base = DateTime.utc_now()

      for i <- 1..4 do
        JobStore.put(build_job("cap_p1_#{i}", inserted_at: DateTime.add(base, i, :second)))
        Process.sleep(2)
      end

      assert length(JobStore.list()) == 4
      assert :ok = JobStore.enforce_cap(3)

      remaining_ids = JobStore.list() |> Enum.map(& &1.id)
      assert length(remaining_ids) == 3
      # The oldest insertion (cap_p1_1) was removed; cap_p1_2..4 remain.
      refute "cap_p1_1" in remaining_ids
      assert Enum.sort(remaining_ids) == ["cap_p1_2", "cap_p1_3", "cap_p1_4"]
    end
  end

  describe "delete/1" do
    test "removes a specific job by id and leaves other rows alone" do
      :ok = JobStore.put(build_job("del_a"))
      :ok = JobStore.put(build_job("del_b"))

      assert JobStore.get("del_a")
      assert JobStore.get("del_b")

      JobStore.delete("del_a")

      refute JobStore.get("del_a")
      assert JobStore.get("del_b")
    end

    test "is a no-op for an unknown id (does not raise)" do
      JobStore.delete("never-existed")
      # Just assert it didn't crash and the table is still empty / usable.
      assert JobStore.list() == []
    end
  end

  describe "clear/0" do
    test "empties the table" do
      :ok = JobStore.put(build_job("clr1"))
      :ok = JobStore.put(build_job("clr2"))
      :ok = JobStore.put(build_job("clr3"))
      assert length(JobStore.list()) == 3

      JobStore.clear()

      assert JobStore.list() == []
    end
  end

  describe "config (ttl_ms / cap)" do
    test "defaults from config/config.exs are 24h ttl and 500 cap" do
      defaults = Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])
      assert defaults[:ttl_ms] == 24 * 60 * 60 * 1000
      assert defaults[:cap] == 500
    end

    test "custom ttl_ms shortens the TTL so sweep removes the row early" do
      prev = Application.get_env(:insta_mealie, InstaMealie.Pipeline)

      Application.put_env(:insta_mealie, InstaMealie.Pipeline, ttl_ms: 1, cap: 500)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, InstaMealie.Pipeline)
          v -> Application.put_env(:insta_mealie, InstaMealie.Pipeline, v)
        end
      end)

      :ok = JobStore.put(build_job("cfg_ttl"))
      assert JobStore.get("cfg_ttl")

      Process.sleep(10)
      assert :ok = JobStore.sweep()

      refute JobStore.get("cfg_ttl")
    end

    test "custom cap is enforced by enforce_cap/0 (called from put/1)" do
      prev = Application.get_env(:insta_mealie, InstaMealie.Pipeline)

      Application.put_env(:insta_mealie, InstaMealie.Pipeline,
        ttl_ms: 24 * 60 * 60 * 1000,
        cap: 2
      )

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:insta_mealie, InstaMealie.Pipeline)
          v -> Application.put_env(:insta_mealie, InstaMealie.Pipeline, v)
        end
      end)

      base = DateTime.utc_now()

      for i <- 1..4 do
        JobStore.put(build_job("cfg_cap_#{i}", inserted_at: DateTime.add(base, i, :second)))
        Process.sleep(2)
      end

      remaining_ids = JobStore.list() |> Enum.map(& &1.id)
      assert length(remaining_ids) == 2
      # put/1 calls enforce_cap after every insert, so after the 4th put
      # only the two most-recent insertions survive.
      assert Enum.sort(remaining_ids) == ["cfg_cap_3", "cfg_cap_4"]
    end
  end
end
