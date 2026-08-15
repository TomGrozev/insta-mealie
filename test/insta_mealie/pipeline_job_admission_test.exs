defmodule InstaMealie.PipelineJobAdmissionTest do
  @moduledoc """
  Dedicated unit tests for `InstaMealie.Pipeline.JobAdmission`.

  The default `max_concurrency` is 3 (see `JobAdmission.max_concurrency/0`).
  Tests below assume that default; if it changes, the queued-position
  assertions need to be revisited.
  """
  use InstaMealie.TestCase

  import ExUnit.CaptureLog

  alias InstaMealie.Pipeline.{Job, JobAdmission, JobStore}

  describe "request/1" do
    test "returns :admitted when within the concurrency cap" do
      assert :admitted = JobAdmission.request("a")
    end

    test "returns {:queued, 1} when at the cap" do
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request("d")
    end

    test "returns {:queued, 2} for the second queued request past the cap" do
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request("d")
      assert {:queued, 2} = JobAdmission.request("e")
    end
  end

  describe "release/1" do
    test "auto-admits the next queued job and starts its GenServer" do
      job_id = "release-admit-" <> unique()
      JobStore.put(build_job(job_id))

      Phoenix.PubSub.subscribe(InstaMealie.PubSub, "jobs")

      # Fill the cap (default max_concurrency = 3).
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request(job_id)

      # Releasing an active slot pops the head of the queue and starts the
      # queued job's GenServer via DynamicSupervisor. The GenServer's
      # handle_continue calls Pipeline.transition which broadcasts :job_updated,
      # so receiving it proves the GenServer was started.
      JobAdmission.release("a")

      assert_receive {:job_updated, %Job{id: ^job_id}}, 2000

      # The job is now in the active set, not the queue.
      assert :not_queued = JobAdmission.position(job_id)
    end

    test "is a no-op for a non-active job (idempotent)" do
      assert :admitted = JobAdmission.request("active-1")

      # Release a job_id that was never admitted or queued.
      JobAdmission.release("never-existed")
      Process.sleep(50)

      # The admission GenServer is still functional and the active set was
      # not disturbed, so we can fill the cap and queue a new job as usual.
      assert :admitted = JobAdmission.request("active-2")
      assert :admitted = JobAdmission.request("active-3")
      assert {:queued, 1} = JobAdmission.request("queued")
      assert {:queued, 1} = JobAdmission.position("queued")
    end

    test "does not crash when the queue is empty" do
      assert pid = Process.whereis(JobAdmission)

      JobAdmission.release("nonexistent")
      Process.sleep(50)

      assert Process.alive?(pid)
      assert :admitted = JobAdmission.request("new")
    end

    test "logs a warning and moves on when the queued job's ETS row is gone (TTL sweep)" do
      job_id = "ttl-sweep-" <> unique()
      JobStore.put(build_job(job_id))

      # Fill the cap and queue the job.
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request(job_id)

      # Simulate a TTL sweep by deleting the ETS row before its turn.
      JobStore.delete(job_id)
      refute JobStore.get(job_id)

      log =
        capture_log(fn ->
          JobAdmission.release("a")
          # Give the cast time to be processed and the warning to be logged.
          Process.sleep(100)
        end)

      assert log =~ "queued job"
      assert log =~ "not found in store"

      # The admission GenServer is still alive and responsive.
      assert pid = Process.whereis(JobAdmission)
      assert Process.alive?(pid)

      # admit_next popped the job from the queue before discovering the
      # missing JobStore row, so it's no longer in the queue.
      assert :not_queued = JobAdmission.position(job_id)
    end
  end

  describe "cancel/1" do
    test "removes a queued job and returns :ok" do
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request("queued")

      assert :ok = JobAdmission.cancel("queued")
    end

    test "returns :not_queued for an active (non-queued) job" do
      assert :admitted = JobAdmission.request("active")
      assert :not_queued = JobAdmission.cancel("active")
    end

    test "returns :not_queued when cancelling the same job_id a second time (no crash)" do
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request("queued")

      assert :ok = JobAdmission.cancel("queued")

      # The second cancel must not crash the admission GenServer and must
      # report :not_queued because the job was just removed from the queue.
      # This guards against the prior bug where the first cancel corrupted
      # state.queue to a bare list, making any subsequent :queue.member/2
      # or :queue.filter/2 call raise ArgumentError.
      assert :not_queued = JobAdmission.cancel("queued")

      # The remaining queued/active jobs are still addressable — the queue
      # is still a proper queue, not a corrupted list.
      assert :not_queued = JobAdmission.position("queued")
    end
  end

  describe "position/1" do
    test "returns the correct 1-indexed position for a queued job" do
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request("q1")
      assert {:queued, 2} = JobAdmission.request("q2")
      assert {:queued, 3} = JobAdmission.request("q3")

      assert {:queued, 1} = JobAdmission.position("q1")
      assert {:queued, 2} = JobAdmission.position("q2")
      assert {:queued, 3} = JobAdmission.position("q3")
    end

    test "returns :not_queued for a non-queued job" do
      assert :not_queued = JobAdmission.position("never-existed")
    end
  end

  describe "reset/0" do
    test "clears all active and queued state" do
      assert :admitted = JobAdmission.request("a")
      assert :admitted = JobAdmission.request("b")
      assert :admitted = JobAdmission.request("c")
      assert {:queued, 1} = JobAdmission.request("queued")

      assert :ok = JobAdmission.reset()

      # After reset the active set is empty, so a fresh request is admitted.
      assert :admitted = JobAdmission.request("new")

      # The previously queued job is gone from the queue.
      assert :not_queued = JobAdmission.position("queued")
    end
  end

  # Minimal Job struct sufficient for JobStore.put/1. JobAdmission only needs
  # the id when starting a GenServer; the rest is populated by the pipeline.
  # `mode: :url` is required so the Job GenServer's handle_continue can
  # match on it (see `InstaMealie.Pipeline.Job.handle_continue/2`).
  defp build_job(id) do
    now = DateTime.utc_now()

    %Job{
      id: id,
      mode: :url,
      state: :created,
      stages: %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))
end
