defmodule InstaMealie.Mealie.LocalImageUploadTest do
  @moduledoc """
  Regression tests for `InstaMealie.Mealie.import_recipe/2`'s local-file
  image upload path and the `fetch_dir` enforcement that constrains it.

  `InstaMealie.Mealie.upload_image/3` has three branches, dispatched by
  `Recipe.image`:

    1. `nil` image                    -> no-op
    2. `http(s)://...` URL            -> `upload_image_url/2`
       (POST /api/recipes/{slug}/image with `%{url: ...}` body)
       — covered by the issue #38 URL regression in `pipeline_test.exs`
    3. path on disk that exists AND is inside `fetch_dir`
                                    -> `upload_image_file/2`
       (PUT /api/recipes/{slug}/image with multipart `image` file part +
       `extension` form field)

  This file covers branch 3 plus the **security gate** around it:
  branch 3 is gated by `fetch_dir`, so an attacker-controlled
  `recipe.image` (LLM-prompt-injected or scraped from a third-party
  page) cannot be coerced into streaming an arbitrary local file
  (`/home/dev/.envrc`, the Instagram session cookie file, SSH keys, ...)
  to Mealie. The fix closes the path: any non-nil, non-URL image path
  that does NOT expand to a regular file inside `fetch_dir` is rejected
  silently with a logged warning. A `fetch_dir: nil` value (caption-only
  job, or a GenServer revived from an ETS snapshot where `fetch_data`
  was reset) fails closed — no local upload is permitted at all.

  The file branch uses `Req.put!` directly with the configured
  `:mealie, :base_url` and **does not** route through the env-stored
  `:mealie_http_adapter` that the URL branch uses. So the only honest
  way to observe the request and the upload result is to spin up a real
  local HTTP server and point `:mealie, :base_url` at it. Wrapping the
  adapter would silently miss the production HTTP path.

  Tests in the first describe block (`import_recipe/2 with a local image
  file inside fetch_dir`) assert both the request shape and the result
  shape so a regression on either side fails the suite:

    a. **Request shape** — a real PUT hits `/api/recipes/{slug}/image`
       carrying a multipart body with an `image` file part (the actual
       bytes on disk, with the file's basename as `filename`) and an
       `extension` form field derived from the path's extension. Catches
       regressions like encoding `{:file, path}` via `Req.put!(..., form:
       [...])` (URL-encoded) instead of `form_multipart: [...]` — the
       former calls `String.Chars.to_string/1` on the file tuple and
       raises `Protocol.UndefinedError`.

    b. **Behaviour** — a failed PUT (here a forced 500) surfaces as
       `{:error, %Error{class: :network}}` from `import_recipe/2`.
       Catches regressions like invoking `upload_image(slug, recipe.image)`
       as a bare statement so the upload failure is silently swallowed
       and the caller sees `{:ok, slug, deep_link(slug)}` despite the
       image never having landed.

  The second describe block (`fetch_dir enforcement`) covers the
  security gate: paths outside `fetch_dir`, paths when `fetch_dir` is
  `nil`, URL images that bypass the gate, and `..`-traversal paths
  that try to escape it. Each test asserts both that no upload was
  attempted (no capture message received) and that the import still
  returns `{:ok, slug, deep_link}` (the recipe is not failed because
  the image was rejected).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias InstaMealie.Error
  alias InstaMealie.Mealie
  alias InstaMealie.Recipe

  # Minimal JPEG: SOI (`FF D8`) + APP0 JFIF segment + a single scan byte +
  # EOI (`FF D9`). Bytes are valid enough that `Req`'s multipart encoder
  # streams them as a real file part; the file extension is what matters
  # for the `extension` form field assertion.
  @fake_jpeg <<
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46,
    0x49,
    0x46,
    0x00,
    0x01,
    0x01,
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0xFF,
    0xD9
  >>

  setup do
    # Pick a free local TCP port and stand up a Plug server on it.
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    # Make the test process reachable from the Plug handler so we can
    # capture the multipart PUT body. `:persistent_term` is process-global
    # (this case is `async: false`); cleanup is in `on_exit`.
    test_pid = self()
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)

    {:ok, server_pid} =
      Bandit.start_link(plug: FakeImageUploadServer, port: port)

    base = "http://127.0.0.1:#{port}"

    # Point `:mealie, :base_url` at the local server so `upload_image_file/2`'s
    # direct `Req.put!` lands on our capture seam. The URL branch and other
    # Mealie calls go through the env-stored `:mealie_http_adapter` (stubbed
    # below), not `Req`.
    prev_mealie = Application.get_env(:insta_mealie, :mealie, [])

    Application.put_env(
      :insta_mealie,
      :mealie,
      Keyword.put(prev_mealie, :base_url, base)
    )

    # Stub the adapter so the non-PUT Mealie calls (GET/PATCH/POST) return
    # a minimal happy path. Without this, the production default adapter
    # would run `Req` against the same Plug, which only handles the
    # PUT endpoint.
    prev_adapter = Application.get_env(:insta_mealie, :mealie_http_adapter)

    Application.put_env(
      :insta_mealie,
      :mealie_http_adapter,
      fn method, path, _body ->
        case {method, path} do
          {:get, "/api/recipes/local-granola"} ->
            # Force the create branch (recipe doesn't exist yet). The stub
            # mimics what the real HttpClassify produces from a 404 response
            # so the create branch runs.
            {:error, Error.new(:not_found, "not found")}

          {:post, "/api/recipes"} ->
            {:ok, %{"slug" => "local-granola"}}

          {:patch, "/api/recipes/local-granola"} ->
            {:ok, %{}}

          _ ->
            {:error, Error.new(:api_error, "unhandled: #{method} #{path}")}
        end
      end
    )

    # Deterministic local image file with a `.jpg` extension. The path
    # must exist on disk for `upload_image/3`'s `File.regular?/1` branch.
    # The image lives inside `tmp_dir` so the happy-path test can pass
    # `tmp_dir` as `fetch_dir` and exercise the legitimate-thumbnail case.
    tmp_dir = Path.join(System.tmp_dir!(), "insta_mealie_local_image_test")
    File.mkdir_p!(tmp_dir)

    image_path =
      Path.join(tmp_dir, "thumbnail-#{System.unique_integer([:positive])}.jpg")

    File.write!(image_path, @fake_jpeg)

    on_exit(fn ->
      Process.exit(server_pid, :kill)

      try do
        :persistent_term.erase({__MODULE__, :test_pid})
      rescue
        ArgumentError -> :ok
      end

      case prev_mealie do
        [] -> Application.delete_env(:insta_mealie, :mealie)
        kw -> Application.put_env(:insta_mealie, :mealie, kw)
      end

      case prev_adapter do
        nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
        fun -> Application.put_env(:insta_mealie, :mealie_http_adapter, fun)
      end

      File.rm(image_path)
    end)

    {:ok, base: base, image_path: image_path, tmp_dir: tmp_dir}
  end

  describe "import_recipe/2 with a local image file inside fetch_dir (happy path)" do
    test "PUTs multipart image+extension to /api/recipes/{slug}/image and surfaces PUT failures",
         %{image_path: image_path, tmp_dir: fetch_dir} do
      recipe = %Recipe{
        name: "Local Granola",
        description: "From a real thumbnail file",
        recipe_yield: "8 servings",
        ingredients: [],
        instructions: [],
        tags: [],
        image: image_path
      }

      # Run the import first; by the time it returns, the Plug handler has
      # already forwarded the multipart PUT to the test process's mailbox
      # (the handler sends the capture message before responding). `fetch_dir`
      # is the tmp_dir the test image lives in — the legitimate thumbnail
      # case. This proves branch 3 still works under the new
      # `import_recipe/2` / `upload_image/3` contract.
      result = Mealie.import_recipe(recipe, fetch_dir)

      # 1. The local-file branch was actually exercised: a PUT reached the
      #    server with a multipart body, an `image` file part with the
      #    bytes we put on disk, and an `extension` form field derived from
      #    the path's extension. These assertions fail if the seam is wrong
      #    (e.g. adapter interception, or upload_image short-circuited).
      assert_receive {:image_uploaded, capture}, 1000

      assert capture.slug == "local-granola"
      assert capture.image_filename == Path.basename(image_path)
      assert capture.image_bytes == @fake_jpeg
      assert capture.extension == "jpg"
      assert capture.content_type =~ "multipart/form-data"

      # 2. The fake server returned 500. A failed image upload must surface
      #    as `{:error, %Error{}}` from `import_recipe/2` — never as
      #    `{:ok, slug, deep_link(slug)}`. HTTP 500 is classified as
      #    `:network` by `InstaMealie.HttpClassify` (see
      #    `lib/insta_mealie/http_classify.ex`); asserting `:api_error`
      #    here would silently drift away from the production classifier.
      assert {:error, %Error{class: :network}} = result
    end
  end

  describe "fetch_dir enforcement (regression: arbitrary local-file read path)" do
    # The five tests in this block close the file-exfiltration path: an
    # attacker-controlled `recipe.image` (LLM-prompt-injected or scraped
    # from a third-party page) must NOT be able to coerce the pipeline
    # into streaming an arbitrary local file — the Instagram session
    # cookie file, `.envrc`, SSH keys, etc. — to Mealie.
    #
    # Each test below exercises a distinct facet of the gate:
    #   * OUTSIDE fetch_dir (this test)  — the canonical attack.
    #   * `fetch_dir: nil`               — caption-only jobs and revived
    #                                       GenServers have no fetch_dir;
    #                                       fail closed.
    #   * URL image                      — bypasses the gate entirely
    #                                       (URL branch is independent of
    #                                       fetch_dir, per the brief).
    #   * `..`-traversal                 — the prefix check uses the
    #                                       EXPANDED path, so a raw
    #                                       `../outside.jpg` inside
    #                                       fetch_dir still fails closed.
    #
    # All four tests use the same shared fake-server setup (no shared
    # image file — each test creates its own fixture, in or out of the
    # fetch_dir it asserts).

    setup do
      # Spin up a fresh fake server + adapter for the gate tests so they
      # don't share fixtures with the happy-path test. The adapter also
      # handles POST /api/recipes/{slug}/image (the URL branch goes through
      # `:mealie_http_adapter`, not the Plug server), so the URL test can
      # capture the URL upload as an adapter call rather than via the
      # capture message.
      test_pid = self()

      {:ok, sock} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)

      :persistent_term.put({__MODULE__, :test_pid}, test_pid)

      {:ok, server_pid} =
        Bandit.start_link(plug: FakeImageUploadServer, port: port)

      base = "http://127.0.0.1:#{port}"

      prev_mealie = Application.get_env(:insta_mealie, :mealie, [])

      Application.put_env(
        :insta_mealie,
        :mealie,
        Keyword.put(prev_mealie, :base_url, base)
      )

      prev_adapter = Application.get_env(:insta_mealie, :mealie_http_adapter)

      Application.put_env(
        :insta_mealie,
        :mealie_http_adapter,
        fn method, path, body ->
          cond do
            # URL branch: POST /api/recipes/{slug}/image with %{url: ...}.
            # Capture so the URL test can assert the body reached Mealie
            # even though `fetch_dir` is irrelevant.
            method == :post and
              String.starts_with?(path, "/api/recipes/") and
              String.ends_with?(path, "/image") and is_map(body) and
                Map.has_key?(body, :url) ->
              send(test_pid, {:url_image_uploaded, path, body})
              {:ok, %{}}

            method == :get and path == "/api/recipes/local-granola" ->
              # Force the create branch (recipe doesn't exist yet).
              {:error, Error.new(:not_found, "not found")}

            method == :get and path == "/api/recipes/url-only-recipe" ->
              {:error, Error.new(:not_found, "not found")}

            method == :get and path == "/api/recipes/traversal-recipe" ->
              {:error, Error.new(:not_found, "not found")}

            method == :get and path == "/api/recipes/nil-fetch-dir-recipe" ->
              {:error, Error.new(:not_found, "not found")}

            method == :post and path == "/api/recipes" ->
              # Echo back a deterministic slug based on the name so each
              # test's slug is predictable.
              name = body[:name] || body["name"] || "untitled"

              slug =
                name
                |> String.downcase()
                |> String.normalize(:nfd)
                |> String.replace(~r/[^a-z0-9]+/u, "-")
                |> String.trim("-")

              {:ok, %{"slug" => slug, "id" => slug}}

            method == :patch and String.starts_with?(path, "/api/recipes/") ->
              {:ok, %{}}

            true ->
              {:error, Error.new(:api_error, "unhandled: #{method} #{path}")}
          end
        end
      )

      on_exit(fn ->
        Process.exit(server_pid, :kill)

        try do
          :persistent_term.erase({__MODULE__, :test_pid})
        rescue
          ArgumentError -> :ok
        end

        case prev_mealie do
          [] -> Application.delete_env(:insta_mealie, :mealie)
          kw -> Application.put_env(:insta_mealie, :mealie, kw)
        end

        case prev_adapter do
          nil -> Application.delete_env(:insta_mealie, :mealie_http_adapter)
          fun -> Application.put_env(:insta_mealie, :mealie_http_adapter, fun)
        end
      end)

      :ok
    end

    test "REJECTS a local image path OUTSIDE fetch_dir — no upload attempted, import still succeeds" do
      # Two separate temp dirs: `fetch_dir` is what the caller passes to
      # `import_recipe/2`; `outside_dir` is where the attacker-controlled
      # `recipe.image` actually lives on disk. The two are unrelated, so
      # any prefix check on `Path.expand(image)` vs `Path.expand(fetch_dir)`
      # fails closed.
      fetch_dir =
        Path.join(
          System.tmp_dir!(),
          "insta_mealie_fetch_dir_#{System.unique_integer([:positive])}"
        )

      outside_dir =
        Path.join(
          System.tmp_dir!(),
          "insta_mealie_outside_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(fetch_dir)
      File.mkdir_p!(outside_dir)

      evil_path = Path.join(outside_dir, "session-cookie.txt")
      File.write!(evil_path, "attacker-controlled bytes")

      on_exit(fn ->
        File.rm(evil_path)
        File.rmdir(outside_dir)
        File.rmdir(fetch_dir)
      end)

      recipe = %Recipe{
        name: "Local Granola",
        description: "Attack scenario: image path is outside fetch_dir",
        recipe_yield: "8 servings",
        ingredients: [],
        instructions: [],
        tags: [],
        image: evil_path
      }

      log =
        capture_log(fn ->
          result = Mealie.import_recipe(recipe, fetch_dir)

          # Import still returns :ok — a rejected image must NOT fail the
          # recipe import (mirrors the existing catch-all's spirit). The
          # caller gets the slug + deep link for the recipe; only the image
          # was skipped.
          assert {:ok, "local-granola", deep_link} = result
          assert deep_link =~ "/g/home/r/local-granola?edit=true"
        end)

      # No PUT to the local server: the file branch must NOT have fired.
      refute_receive {:image_uploaded, _}, 100

      # A warning is logged with the rejected path and slug. Don't assert
      # on the full log line — the production code formats the warning
      # itself; the invariant we care about is "warned with the offending
      # path so an operator can spot it". Asserting the rejected path
      # string appears is enough to catch both "no log at all" and
      # "logged the wrong path".
      assert log =~ "[mealie]"
      assert log =~ "warning"
      assert log =~ evil_path
      assert log =~ "local-granola"
    end

    test "STILL UPLOADS a local image path INSIDE fetch_dir — the legitimate thumbnail case" do
      # Sanity-check on the gate: the happy path still works under the
      # new contract. Same fake-server + adapter as the gate tests above;
      # the image just happens to live inside `fetch_dir`.
      fetch_dir =
        Path.join(System.tmp_dir!(), "insta_mealie_inside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(fetch_dir)
      image_path = Path.join(fetch_dir, "thumb-#{System.unique_integer([:positive])}.jpg")
      File.write!(image_path, @fake_jpeg)

      on_exit(fn ->
        File.rm(image_path)
        File.rmdir(fetch_dir)
      end)

      recipe = %Recipe{
        name: "Local Granola",
        description: "Legitimate thumbnail inside fetch_dir",
        recipe_yield: "8 servings",
        ingredients: [],
        instructions: [],
        tags: [],
        image: image_path
      }

      log =
        capture_log(fn ->
          # The fake Plug server responds 500 on PUT, so we expect
          # `{:error, %Error{class: :network}}` from import_recipe — that
          # PROVES the file branch fired. If the gate were over-rejecting
          # we'd see `{:ok, "local-granola", _}` instead.
          result = Mealie.import_recipe(recipe, fetch_dir)
          assert {:error, %Error{class: :network}} = result
        end)

      # The PUT was attempted (capture sent before the Plug response).
      assert_receive {:image_uploaded, capture}, 1000
      assert capture.image_filename == Path.basename(image_path)
      assert capture.image_bytes == @fake_jpeg

      # No warning was logged — the path was accepted.
      refute log =~ "[mealie]"
      refute log =~ "warning"
    end

    test "REJECTS a local image path when fetch_dir is nil — caption-only / revived-state fail closed" do
      # `fetch_dir: nil` covers two production cases:
      #   * `:caption_only` jobs never had a fetch stage, so no fetch_dir
      #     was ever created.
      #   * A GenServer revived from an ETS snapshot has `fetch_data: nil`
      #     (see `init({:revive, job})` in `lib/insta_mealie/pipeline/job.ex`).
      # The brief mandates fail-closed: refuse any non-URL image when we
      # can't prove it came from the per-job fetch dir.
      fetch_dir = nil

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "insta_mealie_no_fetch_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      image_path = Path.join(tmp_dir, "thumb-#{System.unique_integer([:positive])}.jpg")
      File.write!(image_path, @fake_jpeg)

      on_exit(fn ->
        File.rm(image_path)
        File.rmdir(tmp_dir)
      end)

      recipe = %Recipe{
        name: "Nil Fetch Dir Recipe",
        description: "fetch_dir: nil with a local image path",
        recipe_yield: "8 servings",
        ingredients: [],
        instructions: [],
        tags: [],
        image: image_path
      }

      log =
        capture_log(fn ->
          # Use a name that routes the GET stub through the
          # `:api/recipes/nil-fetch-dir-recipe` arm so the import can
          # actually succeed; the slug returned should match the name.
          recipe = %{recipe | name: "Nil Fetch Dir Recipe"}
          result = Mealie.import_recipe(recipe, fetch_dir)
          assert {:ok, "nil-fetch-dir-recipe", _deep_link} = result
        end)

      refute_receive {:image_uploaded, _}, 100

      assert log =~ "[mealie]"
      assert log =~ "warning"
      assert log =~ image_path
    end

    test "URL image is UNAFFECTED by fetch_dir — URL branch is independent of the gate" do
      # The URL branch (`upload_image_url/2`) goes through
      # `:mealie_http_adapter`, NOT `upload_image_file/2`, so it must
      # bypass the `fetch_dir` gate entirely. Setting `fetch_dir` to a
      # unrelated path proves the URL upload still happens; setting it
      # to `nil` proves the gate doesn't accidentally trigger when
      # fetch_data was never set.
      url = "https://example.com/reel-thumbnail.jpg"

      fetch_dir =
        Path.join(
          System.tmp_dir!(),
          "insta_mealie_unrelated_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(fetch_dir)

      on_exit(fn ->
        File.rmdir(fetch_dir)
      end)

      recipe = %Recipe{
        name: "URL Only Recipe",
        description: "URL image, fetch_dir is unrelated",
        recipe_yield: "8 servings",
        ingredients: [],
        instructions: [],
        tags: [],
        image: url
      }

      log =
        capture_log(fn ->
          assert {:ok, "url-only-recipe", _deep_link} = Mealie.import_recipe(recipe, fetch_dir)
        end)

      # URL branch fired — captured via the adapter, not the Plug server.
      assert_receive {:url_image_uploaded, path, body}, 1000
      assert path =~ "/api/recipes/url-only-recipe/image"
      assert body == %{url: url}

      # No file-branch PUT was attempted.
      refute_receive {:image_uploaded, _}, 50

      # No warning — the URL is unconditionally accepted.
      refute log =~ "[mealie]"
      refute log =~ "warning"
    end

    test "REJECTS a '..'-traversal path that, when expanded, escapes fetch_dir" do
      # The brief mandates the prefix check uses the EXPANDED path, so
      # an attacker who controls the raw `recipe.image` can't sneak
      # outside fetch_dir via `..` segments. This test puts the image
      # OUTSIDE fetch_dir, but expresses it as
      # `Path.join(fetch_dir, "..", "evil.jpg")` so the raw string starts
      # with fetch_dir — a naïve prefix check on the raw path would
      # accept it. The expanded path resolves to the parent of fetch_dir
      # and must be rejected.
      fetch_dir =
        Path.join(
          System.tmp_dir!(),
          "insta_mealie_traversal_#{System.unique_integer([:positive])}"
        )

      parent_dir = Path.dirname(fetch_dir)

      # The traversal target — `..` resolves to parent_dir, which is
      # where `evil.jpg` actually lives. We write the file there to
      # prove the path is `File.regular?/1`-true AND outside fetch_dir;
      # the gate must still reject.
      evil_path = Path.join(parent_dir, "evil-#{System.unique_integer([:positive])}.jpg")
      File.write!(evil_path, @fake_jpeg)

      # `recipe.image` uses the raw traversal form — starts with fetch_dir.
      raw_traversal = Path.join([fetch_dir, "..", Path.basename(evil_path)])

      on_exit(fn ->
        File.rm(evil_path)
      end)

      recipe = %Recipe{
        name: "Traversal Recipe",
        description: "Raw path looks inside fetch_dir but expands outside",
        recipe_yield: "8 servings",
        ingredients: [],
        instructions: [],
        tags: [],
        image: raw_traversal
      }

      log =
        capture_log(fn ->
          assert {:ok, "traversal-recipe", _deep_link} =
                   Mealie.import_recipe(recipe, fetch_dir)
        end)

      # No PUT attempted — the expanded-path prefix check must have
      # rejected this path before the file branch ran.
      refute_receive {:image_uploaded, _}, 100

      # Warning logged with the offending (raw) path so an operator can
      # see what was attempted.
      assert log =~ "[mealie]"
      assert log =~ "warning"
      assert log =~ raw_traversal
    end
  end
end

defmodule FakeImageUploadServer do
  @moduledoc false
  # Minimal Plug server for capturing the local-thumbnail PUT and forcing
  # a 500 so the regression test fails against current code (which
  # discards `upload_image/2`'s return value).
  #
  # Only the production PUT endpoint is implemented. All other methods/
  # paths fall through to a 404 — the test stubs the
  # `:mealie_http_adapter` for everything but the image upload, so this
  # server only ever sees the PUT.

  use Plug.Router

  plug :match
  plug :dispatch

  put "/api/recipes/:slug/image" do
    test_pid =
      :persistent_term.get({InstaMealie.Mealie.LocalImageUploadTest, :test_pid})

    # Read raw body and parse the multipart envelope ourselves instead of
    # going through `Plug.Parsers.MULTIPART`. Req sends a small
    # `multipart/form-data` body with a `boundary=...`; we split on the
    # boundary to recover each part's headers and bytes. This avoids any
    # dependency on Plug body parsing for files we control.
    {:ok, raw_body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    content_type = get_req_header(conn, "content-type") |> List.first() |> to_string()

    boundary =
      case Regex.run(~r/boundary=([^;\r\n]+)/, content_type, capture: :all_but_first) do
        [b] -> b
        _ -> nil
      end

    {image_filename, image_bytes, image_content_type, extension} =
      parse_multipart(raw_body, boundary)

    send(
      test_pid,
      {:image_uploaded,
       %{
         slug: slug,
         image_filename: image_filename,
         image_content_type: image_content_type,
         image_bytes: image_bytes,
         extension: extension,
         content_type: content_type
       }}
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(%{detail: "intentional failure for test"}))
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{detail: "not found"}))
  end

  # Tiny multipart parser: split on boundary, pull headers + body per part.
  # Returns `{filename, bytes, content_type, extension}`.
  defp parse_multipart(_raw, nil), do: {nil, nil, nil, nil}

  defp parse_multipart(raw, boundary) do
    delim = "--#{boundary}"

    raw
    |> String.split(delim)
    |> Enum.drop(1)
    # Drop the trailing closing marker. After splitting on `delim`, the
    # remaining tail is whatever follows the final `--{boundary}` in the
    # body — for the closing boundary `--{boundary}--\r\n` that is
    # `"--\r\n"` (the two extra dashes plus the trailing CRLF). Tolerate
    # the bare `"--"` form too in case a producer omits the final CRLF.
    |> Enum.reject(&(&1 in ["--", "--\r\n"]))
    |> Enum.reduce({nil, nil, nil, nil}, fn part, acc ->
      # Each part is `"\r\n{headers}\r\n\r\n{body}\r\n"`. Split on the
      # FIRST `\r\n\r\n` to separate headers from body; the trailing
      # `\r\n` before the next boundary is stripped below.
      [headers, body] = String.split(part, "\r\n\r\n", parts: 2)

      name =
        case Regex.run(~r/name="([^"]+)"/, headers) do
          [_, n] -> n
          _ -> nil
        end

      filename =
        case Regex.run(~r/filename="([^"]+)"/, headers) do
          [_, f] -> f
          _ -> nil
        end

      part_content_type =
        case Regex.run(~r/Content-Type:\s*([^\r\n]+)/i, headers) do
          [_, ct] -> ct |> String.trim()
          _ -> nil
        end

      body = String.trim_trailing(body, "\r\n")

      cond do
        name == "image" and not is_nil(filename) ->
          {filename, body, part_content_type, elem(acc, 3)}

        name == "extension" ->
          {elem(acc, 0), elem(acc, 1), elem(acc, 2), body}

        true ->
          acc
      end
    end)
  end
end
