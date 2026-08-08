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
end
