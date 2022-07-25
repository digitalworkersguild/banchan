defmodule Banchan.Tags do
  @moduledoc """
  Context module for Tag-related operations.
  """
  import Ecto.Query, warn: false

  alias Banchan.Repo
  alias Banchan.Tags.Tag

  @doc """
  Lists existing tags, doing a prefix match against the `like` argument. If
  `like` is an empty string or nil, no results will be returned. This query is
  mostly used for autocompleting tags.

  Tags themselves are generated and maintained through triggers on various
  tables that support tags, and they're all aggregated into the `tags` table,
  along with their usage counts.
  """
  def list_tags(like, opts \\ []) do
    like =
      if like == "" || is_nil(like) do
        ""
      else
        like <> "%"
      end

    from(tag in Tag,
      select: tag,
      where: ilike(tag.tag, ^like),
      order_by: {:desc, tag.count}
    )
    |> Repo.paginate(
      page: Keyword.get(opts, :page, 1),
      page_size: Keyword.get(opts, :page_size, 20)
    )
  end
end
