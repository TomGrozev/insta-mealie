defmodule InstaMealie.YtDlp.CliTest do
  use ExUnit.Case, async: false

  alias InstaMealie.YtDlp.Cli

  describe "classify_fetch_error/1" do
    test "network errors" do
      assert Cli.classify_fetch_error("ERROR: Unable to download; connection reset by peer") ==
               :network

      assert Cli.classify_fetch_error("TimeoutError: HTTPSConnectionPool timed out") == :network
      assert Cli.classify_fetch_error("Could not resolve host instagram.com") == :network
    end

    test "rate limited" do
      assert Cli.classify_fetch_error("ERROR: You are being rate-limited, please slow down") ==
               :rate_limited

      assert Cli.classify_fetch_error("HTTP Error 429: Too Many Requests") == :rate_limited
    end

    test "cookie / auth required" do
      assert Cli.classify_fetch_error("ERROR: Login required, please log in first") ==
               :cookie_expired

      assert Cli.classify_fetch_error("Authentication failed; cookies expired") ==
               :cookie_expired
    end

    test "ip banned / blocked" do
      assert Cli.classify_fetch_error("ERROR: Your IP address has been blocked") == :ip_banned
      assert Cli.classify_fetch_error("Access denied: 403 Forbidden") == :ip_banned
    end

    test "extraction fallback" do
      assert Cli.classify_fetch_error("ERROR: Unable to extract video data") == :extraction
      assert Cli.classify_fetch_error("This video is private") == :extraction
      assert Cli.classify_fetch_error("some unknown failure") == :extraction
    end
  end

  describe "parse_version/1" do
    test "parses dotted dates" do
      assert Cli.parse_version("2026.07.04") == {2026, 7, 4}
      assert Cli.parse_version("2026.8.1") == {2026, 8, 1}
    end

    test "parses hyphenated versions" do
      assert Cli.parse_version("2026-07-04") == {2026, 7, 4}
    end

    test "parses two-part versions" do
      assert Cli.parse_version("2026.7") == {2026, 7, 0}
    end

    test "rejects unparseable" do
      assert Cli.parse_version("not-a-version") == :unknown
      assert Cli.parse_version("abc.def.ghi") == :unknown
    end
  end

  describe "maybe_add_cookies/2" do
    test "adds --cookies when opts path exists" do
      dir = System.tmp_dir!()

      cookie =
        Path.join(
          dir,
          "cookies_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}.txt"
        )

      File.write!(cookie, "dummy")
      args = Cli.maybe_add_cookies(["--no-playlist"], cookies_path: cookie)
      assert args == ["--no-playlist", "--cookies", cookie]
    end

    test "omits cookies when opts path missing" do
      args = Cli.maybe_add_cookies(["--no-playlist"], cookies_path: "/no/such/file.txt")
      assert args == ["--no-playlist"]
    end

    test "reads ig_cookies_path from app config when not in opts" do
      dir = System.tmp_dir!()

      cookie =
        Path.join(
          dir,
          "cfg_cookie_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}.txt"
        )

      File.write!(cookie, "dummy")
      original_config = Application.get_env(:insta_mealie, :insta_mealie, [])
      Application.put_env(:insta_mealie, :insta_mealie, ig_cookies_path: cookie)
      args = Cli.maybe_add_cookies(["x"], [])
      assert args == ["x", "--cookies", cookie]
      Application.put_env(:insta_mealie, :insta_mealie, original_config)
    end
  end

  describe "preflight!/0" do
    test "raises with install hint when yt-dlp is missing, otherwise caches and cleans up" do
      if System.find_executable("yt-dlp") == nil do
        assert_raise RuntimeError, ~r/pipx install/, fn -> Cli.preflight!() end
      else
        try do
          Cli.preflight!()
        rescue
          _ -> :ok
        end

        :persistent_term.erase(:insta_mealie_ytdlp_preflight)
      end
    end
  end

  describe "build_metadata_args/1" do
    test "includes --skip-download and info/comments/thumbnail flags" do
      args = Cli.build_metadata_args("/tmp/out.%(ext)s")
      assert "--skip-download" in args
      assert "--write-info-json" in args
      assert "--write-comments" in args
      assert "--write-thumbnail" in args
    end

    test "does not include audio extraction or video remux flags" do
      args = Cli.build_metadata_args("/tmp/out.%(ext)s")
      refute "--extract-audio" in args
      refute "--audio-format" in args
      refute "--audio-quality" in args
    end

    test "does not include -f (format selection)" do
      args = Cli.build_metadata_args("/tmp/out.%(ext)s")
      refute "-f" in args
    end

    test "includes -o with the output template" do
      args = Cli.build_metadata_args("/tmp/out.%(ext)s")
      o_idx = Enum.find_index(args, &(&1 == "-o"))
      assert o_idx
      assert Enum.at(args, o_idx + 1) == "/tmp/out.%(ext)s"
    end
  end

  describe "build_audio_args/1" do
    test "includes --extract-audio, mp3, 64K, and bestaudio/best" do
      args = Cli.build_audio_args("/tmp/out.%(ext)s")
      assert "--extract-audio" in args
      audio_fmt_idx = Enum.find_index(args, &(&1 == "--audio-format"))
      assert audio_fmt_idx
      assert Enum.at(args, audio_fmt_idx + 1) == "mp3"

      audio_q_idx = Enum.find_index(args, &(&1 == "--audio-quality"))
      assert audio_q_idx
      assert Enum.at(args, audio_q_idx + 1) == "64K"

      f_idx = Enum.find_index(args, &(&1 == "-f"))
      assert f_idx
      assert Enum.at(args, f_idx + 1) == "bestaudio/best"
    end

    test "does not include metadata-write or skip-download flags" do
      args = Cli.build_audio_args("/tmp/out.%(ext)s")
      refute "--skip-download" in args
      refute "--write-info-json" in args
      refute "--write-comments" in args
      refute "--write-thumbnail" in args
    end

    test "does not include video remux flags" do
      args = Cli.build_audio_args("/tmp/out.%(ext)s")
      refute "--remux-video" in args
    end

    test "includes -o with the output template" do
      args = Cli.build_audio_args("/tmp/out.%(ext)s")
      o_idx = Enum.find_index(args, &(&1 == "-o"))
      assert o_idx
      assert Enum.at(args, o_idx + 1) == "/tmp/out.%(ext)s"
    end
  end

  describe "classify_fetch_error/1 additional patterns" do
    test "detects each rate-limited pattern" do
      assert Cli.classify_fetch_error("rate-limited") == :rate_limited
      assert Cli.classify_fetch_error("rate limited") == :rate_limited
      assert Cli.classify_fetch_error("too many requests") == :rate_limited
      assert Cli.classify_fetch_error("429") == :rate_limited
    end

    test "detects each cookie / auth pattern" do
      assert Cli.classify_fetch_error("login required") == :cookie_expired
      assert Cli.classify_fetch_error("log in required") == :cookie_expired
      assert Cli.classify_fetch_error("not logged in") == :cookie_expired
      assert Cli.classify_fetch_error("cookies expired") == :cookie_expired
      assert Cli.classify_fetch_error("authentication failed") == :cookie_expired
      assert Cli.classify_fetch_error("please log in") == :cookie_expired
      assert Cli.classify_fetch_error("sign in to continue") == :cookie_expired
    end

    test "detects each ip_banned pattern" do
      assert Cli.classify_fetch_error("blocked by server") == :ip_banned
      assert Cli.classify_fetch_error("you have been banned") == :ip_banned
      assert Cli.classify_fetch_error("access denied") == :ip_banned
      assert Cli.classify_fetch_error("error 403") == :ip_banned
      assert Cli.classify_fetch_error("ip address flagged") == :ip_banned
      assert Cli.classify_fetch_error("ip-address flagged") == :ip_banned
    end

    test "detects each network pattern" do
      assert Cli.classify_fetch_error("connection reset") == :network
      assert Cli.classify_fetch_error("timed out") == :network
      assert Cli.classify_fetch_error("timeout") == :network
      assert Cli.classify_fetch_error("name or service not known") == :network
      assert Cli.classify_fetch_error("could not resolve host") == :network
      assert Cli.classify_fetch_error("failed to resolve") == :network
      assert Cli.classify_fetch_error("network unreachable") == :network
      assert Cli.classify_fetch_error("http error 502") == :network
      assert Cli.classify_fetch_error("errno -2") == :network
      assert Cli.classify_fetch_error("unable to download") == :network
      assert Cli.classify_fetch_error("tunnel connection") == :network
    end

    test "is case insensitive" do
      assert Cli.classify_fetch_error("RATE-LIMITED") == :rate_limited
      assert Cli.classify_fetch_error("LOGIN REQUIRED") == :cookie_expired
      assert Cli.classify_fetch_error("ACCESS DENIED") == :ip_banned
      assert Cli.classify_fetch_error("CONNECTION RESET") == :network
    end

    test "rate_limited has priority over network when both present" do
      assert Cli.classify_fetch_error("rate-limited due to network congestion") == :rate_limited
    end

    test "cookie_expired has priority over network when both present" do
      assert Cli.classify_fetch_error("login required; connection failed") == :cookie_expired
    end
  end

  describe "parse_version/1 edge cases" do
    test "leading whitespace yields :unknown" do
      assert Cli.parse_version(" 2026.07.04") == :unknown
    end

    test "single component yields :unknown" do
      assert Cli.parse_version("2026") == :unknown
    end

    test "four components yield :unknown (3rd part unparseable)" do
      assert Cli.parse_version("2026.7.4.1") == :unknown
    end

    test "empty string yields :unknown" do
      assert Cli.parse_version("") == :unknown
    end

    test "two-part hyphenated version pads a zero day" do
      assert Cli.parse_version("2026-07") == {2026, 7, 0}
    end
  end

  describe "preflight_state/0 and degraded?/0" do
    @preflight_key :insta_mealie_ytdlp_preflight

    setup do
      on_exit(fn -> :persistent_term.erase(@preflight_key) end)
      :ok
    end

    test "preflight_state/0 returns nil when nothing is cached" do
      :persistent_term.erase(@preflight_key)
      assert Cli.preflight_state() == nil
    end

    test "preflight_state/0 returns the cached map when set" do
      state = %{version: {2026, 7, 4}, impersonation: :full, binary: "/usr/bin/ytdlp"}
      :persistent_term.put(@preflight_key, state)
      assert Cli.preflight_state() == state
    end

    test "degraded?/0 is false when impersonation is :full" do
      :persistent_term.put(@preflight_key, %{version: {2026, 7, 4}, impersonation: :full})
      refute Cli.degraded?()
    end

    test "degraded?/0 is true when impersonation is :degraded" do
      :persistent_term.put(@preflight_key, %{version: {2026, 7, 4}, impersonation: :degraded})
      assert Cli.degraded?()
    end

    test "degraded?/0 is false when no preflight has run" do
      :persistent_term.erase(@preflight_key)
      refute Cli.degraded?()
    end
  end

  describe "maybe_add_cookies/2 additional" do
    test "returns args unchanged when no cookies_path and no app config" do
      original_config = Application.get_env(:insta_mealie, :insta_mealie, [])

      on_exit(fn ->
        if original_config == [] do
          Application.delete_env(:insta_mealie, :insta_mealie)
        else
          Application.put_env(:insta_mealie, :insta_mealie, original_config)
        end
      end)

      Application.delete_env(:insta_mealie, :insta_mealie)
      assert Cli.maybe_add_cookies(["--no-playlist"], []) == ["--no-playlist"]
    end

    test "returns args unchanged when cookies_path points to missing file" do
      assert Cli.maybe_add_cookies(["--no-playlist"], cookies_path: "/no/such/cookies.txt") ==
               ["--no-playlist"]
    end

    test "opts cookies_path takes precedence over app config" do
      dir = System.tmp_dir!()

      make_cookie = fn prefix ->
        Path.join(
          dir,
          "#{prefix}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}.txt"
        )
      end

      app_cookie = make_cookie.("app")
      opts_cookie = make_cookie.("opts")
      File.write!(app_cookie, "dummy")
      File.write!(opts_cookie, "dummy")

      original_config = Application.get_env(:insta_mealie, :insta_mealie, [])
      Application.put_env(:insta_mealie, :insta_mealie, ig_cookies_path: app_cookie)

      on_exit(fn ->
        if original_config == [] do
          Application.delete_env(:insta_mealie, :insta_mealie)
        else
          Application.put_env(:insta_mealie, :insta_mealie, original_config)
        end
      end)

      args = Cli.maybe_add_cookies(["x"], cookies_path: opts_cookie)
      assert args == ["x", "--cookies", opts_cookie]
    end
  end
end
