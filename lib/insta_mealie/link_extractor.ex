defmodule InstaMealie.LinkExtractor do
  @moduledoc """
  Pure candidate-link extraction for a reel's caption and OP comments.

  See ADR-0006. The pipeline calls `extract/2` to build the candidate list
  passed to the router; `scrape_link` follows up by trying each candidate via
  Mealie's `POST /api/recipes/test-scrape-url`.
  """

  # Greedy non-whitespace match — trailing punctuation is stripped below.
  @url_regex ~r/https?:\/\/\S+/

  # `)`, `]`, `.`, `,`, `!` are valid URL chars per RFC 3986 only inside
  # specific positions; we conservatively strip any run of these at the end.
  @trailing_punctuation ~r/[\)\]\.,!]+$/

  # Hosts dropped entirely (case-insensitive, `www.` prefix ignored).
  # Subdomain match: `m.instagram.com` is also dropped.
  @skip_hosts ~w(
    instagram.com
    instagr.am
    l.instagram.com
    linktr.ee
    linkin.bio
    beacons.ai
    campsite.bio
    milkshake.app
    koji.to
    shor.by
    lnk.bio
    bio.link
    linktree.com
    shopmy.us
    liketoknow.it
    shopltk.com
    rewardstyle.com
  )

  @spec extract(String.t(), list(map())) :: [String.t()]
  def extract(caption, comments) do
    caption_urls = urls_in(caption)
    comment_urls = Enum.flat_map(comments || [], fn comment -> urls_in(comment_text(comment)) end)

    (caption_urls ++ comment_urls)
    |> Enum.map(&strip_trailing/1)
    |> Enum.reject(&skip?/1)
    |> Enum.uniq()
  end

  defp urls_in(text) when is_binary(text) do
    @url_regex
    |> Regex.scan(text)
    |> Enum.map(fn [match] -> match end)
  end

  defp urls_in(_), do: []

  defp comment_text(%{text: t}), do: t
  defp comment_text(%{"text" => t}), do: t
  defp comment_text(_), do: ""

  defp strip_trailing(url) do
    String.replace(url, @trailing_punctuation, "")
  end

  defp skip?(url) do
    %URI{host: host, path: path} = URI.parse(url)
    normalized = (host || "") |> String.downcase() |> String.trim_leading("www.")
    host_matches_skip?(normalized) or amazon_shop?(normalized, path || "")
  end

  defp host_matches_skip?(host) do
    Enum.any?(@skip_hosts, fn skip -> host == skip or String.ends_with?(host, "." <> skip) end)
  end

  defp amazon_shop?(host, path) do
    host == "amazon.com" and String.starts_with?(path, "/shop/")
  end
end
