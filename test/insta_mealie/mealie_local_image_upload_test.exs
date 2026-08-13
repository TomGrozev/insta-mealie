defmodule InstaMealie.Mealie.LocalImageUploadTest do
  @moduledoc """
  Regression test for the local-thumbnail upload path of
  `InstaMealie.Mealie.import_recipe/1`.

  `InstaMealie.Mealie.upload_image/2` has three branches, dispatched by
  `Recipe.image`:

    1. `nil` image                    -> no-op
    2. `http(s)://...` URL            -> `upload_image_url/2`
       (POST /api/recipes/{slug}/image with `%{url: ...}` body)
       — covered by the issue #38 URL regression in `pipeline_test.exs`
    3. path on disk that exists       -> `upload_image_file/2`
       (PUT /api/recipes/{slug}/image with multipart `image` file part +
       `extension` form field)

  This file covers branch 3. It is intentionally distinct from the
  URL-branch test: the file branch uses `Req.put!` directly with the
  configured `:mealie, :base_url` and **does not** route through the
  env-stored `:mealie_http_adapter` that the URL branch uses. So the only
  honest way to observe the request and the upload result is to spin up a
  real local HTTP server and point `:mealie, :base_url` at it. Wrapping the
  adapter would silently miss the production HTTP path.

  The test asserts both the request shape and the result shape so a
  regression on either side fails the suite:

    a. **Request shape** — a real PUT hits `/api/recipes/{slug}/image`
       carrying a multipart body with an `image` file part (the actual
       bytes on disk, with the file's basename as `filename`) and an
       `extension` form field derived from the path's extension. Catches
       regressions like encoding `{:file, path}` via `Req.put!(..., form:
       [...])` (URL-encoded) instead of `form_multipart: [...]` — the
       former calls `String.Chars.to_string/1` on the file tuple and
       raises `Protocol.UndefinedError`.

    b. **Behaviour** — a failed PUT (here a forced 500) surfaces as
       `{:error, %Error{class: :network}}` from `import_recipe/1`. Catches
       regressions like invoking `upload_image(slug, recipe.image)` as a
       bare statement so the upload failure is silently swallowed and the
       caller sees `{:ok, slug, deep_link(slug)}` despite the image never
       having landed.

  Fixing only the request-shape side would still fail the behaviour
  assertion; fixing only the behaviour side would still fail the capture
  assertion because no PUT would ever be sent. Both must hold.
  """

  use ExUnit.Case, async: false

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
            # Force the create branch (recipe doesn't exist yet).
            {:error, Error.new(:api_error, "not found")}

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
    # must exist on disk for `upload_image/2`'s `File.exists?/1` branch.
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

    {:ok, base: base, image_path: image_path}
  end

  describe "import_recipe/1 with a local image file (upload_image_file/2 path)" do
    test "PUTs multipart image+extension to /api/recipes/{slug}/image and surfaces PUT failures",
         %{image_path: image_path} do
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
      # (the handler sends the capture message before responding).
      result = Mealie.import_recipe(recipe)

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
      #    as `{:error, %Error{}}` from `import_recipe/1` — never as
      #    `{:ok, slug, deep_link(slug)}`. HTTP 500 is classified as
      #    `:network` by `InstaMealie.HttpClassify` (see
      #    `lib/insta_mealie/http_classify.ex`); asserting `:api_error`
      #    here would silently drift away from the production classifier.
      assert {:error, %Error{class: :network}} = result
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
