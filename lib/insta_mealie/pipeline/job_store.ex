defmodule InstaMealie.Pipeline.JobStore do
  @moduledoc "SQLite-backed job persistence with TTL sweep and row cap."

  @db_key :insta_mealie_jobstore_db
  @table "jobs"

  defp db_path do
    Application.get_env(:insta_mealie, :insta_mealie, [])[:db_path] ||
      System.get_env("INSTA_MEALIE_DB_PATH") ||
      "/tmp/insta_mealie_jobs.db"
  end

  @doc "Open DB and create schema. Called once at boot by Sweeper."
  def init_db do
    path = db_path()
    path |> Path.dirname() |> File.mkdir_p!()

    {:ok, db} = Exqlite.Sqlite3.open(path)
    Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout=5000")

    Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS #{@table} (
        id TEXT PRIMARY KEY,
        data BLOB NOT NULL,
        state TEXT NOT NULL DEFAULT 'created',
        inserted_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      )
    """)

    Exqlite.Sqlite3.execute(db, "CREATE INDEX IF NOT EXISTS idx_jobs_inserted ON #{@table}(inserted_at DESC)")
    Exqlite.Sqlite3.execute(db, "CREATE INDEX IF NOT EXISTS idx_jobs_expires ON #{@table}(expires_at)")

    # Mark in-flight jobs as interrupted on recovery
    Exqlite.Sqlite3.execute(db, """
      UPDATE #{@table} SET state = 'interrupted'
      WHERE state IN ('created', 'running', 'caption_pasting', 'needs_review')
    """)

    :persistent_term.put(@db_key, db)
    :ok
  end

  def put(job) do
    case get_db() do
      {:error, _} = err ->
        err

      {:ok, db} ->
        now_ms = System.system_time(:millisecond)
        expires_at = now_ms + ttl_ms()
        data = :erlang.term_to_binary(job)
        state = Atom.to_string(job.state)
        ins_epoch = to_epoch_ms(job.inserted_at)

        run_write(
          db,
          """
          INSERT OR REPLACE INTO #{@table} (id, data, state, inserted_at, updated_at, expires_at)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          """,
          [job.id, data, state, ins_epoch, now_ms, expires_at]
        )

        enforce_cap(db)
        :ok
    end
  end

  def get(id) do
    with {:ok, db} <- get_db(),
         {:ok, rows} <-
           run_read(db, "SELECT state, data FROM #{@table} WHERE id = ?1", [id]) do
      case rows do
        [[state, data]] when is_binary(data) ->
          job = :erlang.binary_to_term(data)
          # The `state` column is authoritative (it backs the interrupted-state
          # recovery update in init_db/0, which mutates the column but not the
          # cached BLOB). Override the struct's state with the column's value.
          state_atom = if is_binary(state), do: String.to_existing_atom(state), else: state
          %{job | state: state_atom}

        _ ->
          nil
      end
    end
  end

  def list do
    with {:ok, db} <- get_db(),
         {:ok, rows} <-
           run_read(
             db,
             "SELECT state, data FROM #{@table} ORDER BY inserted_at DESC LIMIT ?1",
             [cap()]
           ) do
      Enum.map(rows, fn [state, data] ->
        job = :erlang.binary_to_term(data)
        state_atom = if is_binary(state), do: String.to_existing_atom(state), else: state
        %{job | state: state_atom}
      end)
    end
  end

  def delete(id) do
    with {:ok, db} <- get_db() do
      run_write(db, "DELETE FROM #{@table} WHERE id = ?1", [id])
      :ok
    end
  end

  def clear do
    with {:ok, db} <- get_db() do
      run_write(db, "DELETE FROM #{@table}", [])
      :ok
    end
  end

  def sweep do
    with {:ok, db} <- get_db() do
      now_ms = System.system_time(:millisecond)
      run_write(db, "DELETE FROM #{@table} WHERE expires_at < ?1", [now_ms])
      enforce_cap(db)
      :ok
    end
  end

  # -- private --

  defp get_db do
    case :persistent_term.get(@db_key, nil) do
      nil -> {:error, :db_not_initialized}
      db -> {:ok, db}
    end
  end

  defp run_write(db, sql, args) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, args) do
      try do
        case Exqlite.Sqlite3.multi_step(db, stmt) do
          {:done, _rows} -> :ok
          {:rows, _rows} -> :ok
          {:error, reason} -> {:error, reason}
          :busy -> {:error, :busy}
        end
      after
        Exqlite.Sqlite3.release(db, stmt)
      end
    end
  end

  defp run_read(db, sql, args) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, args) do
      try do
        case Exqlite.Sqlite3.fetch_all(db, stmt) do
          {:ok, rows} -> {:ok, rows}
          {:error, reason} -> {:error, reason}
        end
      after
        Exqlite.Sqlite3.release(db, stmt)
      end
    end
  end

  defp enforce_cap(db) do
    with {:ok, [[count]]} <- run_read(db, "SELECT COUNT(*) FROM #{@table}", []),
         cap = cap(),
         true <- count > cap do
      excess = count - cap
      run_write(db, "DELETE FROM #{@table} WHERE id IN (SELECT id FROM #{@table} ORDER BY updated_at ASC LIMIT ?1)", [excess])
    else
      _ -> :ok
    end
  end

  defp ttl_ms do
    Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])[:ttl_ms] || 24 * 60 * 60 * 1000
  end

  defp cap do
    Application.get_env(:insta_mealie, InstaMealie.Pipeline, [])[:cap] || 500
  end

  defp to_epoch_ms(nil), do: System.system_time(:millisecond)
  defp to_epoch_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
end
