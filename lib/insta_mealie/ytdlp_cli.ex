defmodule InstaMealie.YtDlp.Cli do
  @moduledoc """
  Real yt-dlp wrapper invoked via `System.cmd` (ADR 0002).

  Two-stage fetch contract:

    * **Stage 1 — `fetch_metadata/2`** runs yt-dlp with `--skip-download`,
      `--write-info-json`, `--write-comments`, and `--write-thumbnail` to
      collect author, caption, comments, and thumbnail path without
      downloading media. Returns an internal `:fetch_dir` key for the later
      audio request.

    * **Stage 2 — `fetch_audio/2`** runs yt-dlp with
      `--extract-audio --audio-format mp3 --audio-quality 64K` to download
      audio into the per-fetch directory and returns `%{audio_path: path}`.

  Both return `{:ok, map()} | {:error, atom(), term()}`.

  Fetch failures are classified into the standard verdict vocabulary
  (extraction | rate_limited | cookie_expired | network | ip_banned).

  Boot preflight (`preflight!/0`) verifies yt-dlp presence, version, and
  impersonation support, caching the result in `:persistent_term`.
  """
  @behaviour InstaMealie.YtDlp

  require Logger

  @min_version {2026, 7, 4}
  @preflight_key :insta_mealie_ytdlp_preflight

  # ---- fetch_metadata ----

  @impl true
  def fetch_metadata(url, opts \\ []) when is_binary(url) do
    case System.find_executable("yt-dlp") do
      nil ->
        {:error, :extraction, "yt-dlp binary not found on PATH"}

      ytdlp ->
        host = url |> URI.parse() |> Map.get(:host, "unknown")
        dir = temp_dir!()
        out_tmpl = Path.join(dir, "reel.%(ext)s")
        args = build_metadata_args(out_tmpl) |> maybe_add_cookies(opts)
        start = System.monotonic_time(:millisecond)

        case System.cmd(ytdlp, args ++ [url], stderr_to_stdout: true) do
          {_out, 0} ->
            elapsed = System.monotonic_time(:millisecond) - start
            Logger.info("[ytdlp] metadata #{host} completed in #{elapsed}ms")
            parse_metadata_result(dir)

          {stderr, _code} ->
            elapsed = System.monotonic_time(:millisecond) - start
            class = classify_fetch_error(stderr)
            Logger.error("[ytdlp] metadata #{host} failed in #{elapsed}ms (#{class})")
            {:error, class, sanitize(stderr)}
        end
    end
  rescue
    e in RuntimeError -> {:error, :extraction, Exception.message(e)}
  end

  # ---- fetch_audio ----

  @impl true
  def fetch_audio(url, opts \\ []) when is_binary(url) do
    case System.find_executable("yt-dlp") do
      nil ->
        {:error, :extraction, "yt-dlp binary not found on PATH"}

      ytdlp ->
        host = url |> URI.parse() |> Map.get(:host, "unknown")
        dir = opts[:output_dir] || temp_dir!()
        out_tmpl = Path.join(dir, "reel.%(ext)s")
        args = build_audio_args(out_tmpl) |> maybe_add_cookies(opts)
        start = System.monotonic_time(:millisecond)

        case System.cmd(ytdlp, args ++ [url], stderr_to_stdout: true) do
          {_out, 0} ->
            elapsed = System.monotonic_time(:millisecond) - start
            Logger.info("[ytdlp] audio #{host} completed in #{elapsed}ms")
            parse_audio_result(dir)

          {stderr, _code} ->
            elapsed = System.monotonic_time(:millisecond) - start
            class = classify_fetch_error(stderr)
            Logger.error("[ytdlp] audio #{host} failed in #{elapsed}ms (#{class})")
            {:error, class, sanitize(stderr)}
        end
    end
  rescue
    e in RuntimeError -> {:error, :extraction, Exception.message(e)}
  end

  # ---- preflight ----

  @doc """
  Run the boot preflight (ADR 0002): verify yt-dlp presence, version
  (>= #{inspect(@min_version)}), and impersonation support. Caches the result
  in `:persistent_term` and raises on absence / incompatible version. A
  missing or unsupported impersonation target degrades gracefully (returns
  `:degraded`) rather than raising.
  """
  def preflight! do
    ytdlp =
      System.find_executable("yt-dlp") ||
        raise(preflight_hint("yt-dlp was not found on PATH"))

    version = run_version(ytdlp)
    parsed = parse_version(version)

    version =
      case parsed do
        :unknown ->
          raise(preflight_hint("yt-dlp version is unparseable: #{version}"))

        v when v < @min_version ->
          raise(
            preflight_hint(
              "yt-dlp version #{format_version(v)} is older than required #{format_version(@min_version)}"
            )
          )

        v ->
          v
      end

    impersonation =
      case run_impersonate_targets(ytdlp) do
        {:ok, []} -> :degraded
        {:ok, _targets} -> :full
        {:error, _} -> :degraded
      end

    state = %{version: version, impersonation: impersonation, binary: ytdlp}
    :persistent_term.put(@preflight_key, state)

    if impersonation == :degraded do
      Logger.warning(
        "[insta_mealie] yt-dlp browser impersonation is unavailable; " <>
          "running in caption-only degraded mode"
      )
    end

    state
  end

  @doc "Returns the cached preflight state (or `nil` if preflight never ran)."
  def preflight_state, do: :persistent_term.get(@preflight_key, nil)

  @doc "True when preflight reported yt-dlp cannot impersonate (caption-only mode)."
  def degraded?, do: match?(%{impersonation: :degraded}, preflight_state())

  # ---- internals (exposed for unit tests) ----

  @doc false
  def build_metadata_args(out_tmpl) do
    [
      "--no-playlist",
      "--no-warnings",
      "--quiet",
      "--no-simulate",
      "--skip-download",
      "--write-info-json",
      "--write-comments",
      "--write-thumbnail",
      "-o",
      out_tmpl
    ]
  end

  @doc false
  def build_audio_args(out_tmpl) do
    [
      "--no-playlist",
      "--no-warnings",
      "--quiet",
      "--no-simulate",
      "--extract-audio",
      "--audio-format",
      "mp3",
      "--audio-quality",
      "64K",
      "-f",
      "bestaudio/best",
      "-o",
      out_tmpl
    ]
  end

  @doc false
  def maybe_add_cookies(args, opts) when is_list(args) do
    cookies =
      opts[:cookies_path] ||
        Application.get_env(:insta_mealie, :insta_mealie, [])[:ig_cookies_path]

    if is_binary(cookies) and File.exists?(cookies) do
      args ++ ["--cookies", cookies]
    else
      args
    end
  end

  @doc false
  def classify_fetch_error(stderr) when is_binary(stderr) do
    s = String.downcase(stderr)

    cond do
      String.contains?(s, ["rate-limited", "rate limited", "too many requests", "429"]) ->
        :rate_limited

      String.contains?(s, [
        "login required",
        "log in required",
        "not logged in",
        "cookies",
        "authentication",
        "please log in",
        "sign in"
      ]) ->
        :cookie_expired

      String.contains?(s, [
        "blocked",
        "banned",
        "access denied",
        "403",
        "ip address",
        "ip-address"
      ]) ->
        :ip_banned

      String.contains?(s, [
        "connection",
        "timed out",
        "timeout",
        "name or service",
        "could not resolve",
        "failed to resolve",
        "network",
        "http error 5",
        "errno",
        "unable to download",
        "tunnel"
      ]) ->
        :network

      true ->
        :extraction
    end
  end

  @doc false
  def parse_version(str) when is_binary(str) do
    case String.split(str, ~r"[.\-]", parts: 3) do
      [y, m, d] -> to_tuple_or_unknown([y, m, d])
      [y, m] -> to_tuple_or_unknown([y, m, "0"])
      _ -> :unknown
    end
  end

  # ---- helpers ----

  defp temp_dir! do
    dir =
      Path.join([
        System.tmp_dir!(),
        "insta_mealie",
        "fetch_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      ])

    File.mkdir_p!(dir)
    dir
  end

  defp parse_metadata_result(dir) do
    info_path = Path.wildcard(Path.join(dir, "*.info.json")) |> List.first()
    unless info_path, do: raise("yt-dlp produced no info json")

    info = File.read!(info_path) |> Jason.decode!()

    author =
      info["uploader"] || info["uploader_id"] || info["channel"] ||
        info["owner_username"] || ""

    caption =
      [info["title"], info["description"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    comments =
      case info["comments"] do
        list when is_list(list) ->
          Enum.map(list, fn c ->
            %{
              author: c["author"] || c["author_id"] || "",
              text: c["text"] || ""
            }
          end)

        _ ->
          []
      end

    thumbnail_path =
      Path.wildcard(Path.join(dir, "*.jpg")) |> List.first() ||
        Path.wildcard(Path.join(dir, "*.jpeg")) |> List.first() ||
        Path.wildcard(Path.join(dir, "*.webp")) |> List.first() ||
        Path.wildcard(Path.join(dir, "*.png")) |> List.first()

    {:ok,
     %{
       author: author,
       caption: caption,
       comments: comments,
       thumbnail_path: thumbnail_path,
       fetch_dir: dir
     }}
  end

  defp parse_audio_result(dir) do
    audio_path = Path.wildcard(Path.join(dir, "*.mp3")) |> List.first()
    unless audio_path, do: raise("yt-dlp produced no audio file")
    {:ok, %{audio_path: audio_path}}
  end

  defp sanitize(stderr) when byte_size(stderr) > 800 do
    stderr |> binary_part(0, 800) |> Kernel.<>("… (truncated)")
  end

  defp sanitize(stderr), do: stderr

  defp run_version(ytdlp) do
    {out, _code} = System.cmd(ytdlp, ["--version"], stderr_to_stdout: true)
    String.trim(out)
  end

  defp run_impersonate_targets(ytdlp) do
    case System.cmd(ytdlp, ["--list-impersonate-targets"], stderr_to_stdout: true) do
      {out, 0} ->
        targets =
          out
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, targets}

      {_out, _code} ->
        {:error, :no_targets}
    end
  end

  defp to_tuple_or_unknown(parts) do
    list = Enum.map(parts, &String.to_integer/1)
    List.to_tuple(list)
  rescue
    ArgumentError -> :unknown
  end

  defp format_version({y, m, d}), do: "#{y}.#{m}.#{d}"

  defp preflight_hint(detail) do
    """
    yt-dlp is required but #{detail}.
    Install or upgrade with: pipx install "yt-dlp[default,curl-cffi]"
    """
  end
end
