defmodule RuleMaven.InviteCodes do
  @moduledoc """
  Invite code management — generation, validation, consumption.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Repo
  alias RuleMaven.InviteCodes.InviteCode

  @doc """
  Generates a new invite code.
  """
  def create_code(created_by_id, opts \\ []) do
    code = generate_code()

    attrs =
      %{
        code: code,
        created_by_id: created_by_id,
        max_uses: Keyword.get(opts, :max_uses, 1),
        expires_at: Keyword.get(opts, :expires_at)
      }

    %InviteCode{}
    |> InviteCode.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Validates an invite code. Returns {:ok, code} or {:error, reason}.
  """
  def validate_code(nil), do: {:error, "Invalid invite code."}
  def validate_code(""), do: {:error, "Invalid invite code."}

  def validate_code(code) when is_binary(code) do
    case Repo.get_by(InviteCode, code: code) do
      nil ->
        {:error, "Invalid invite code."}

      %InviteCode{active: false} ->
        {:error, "This invite code is no longer active."}

      %InviteCode{expires_at: expires} = ic when not is_nil(expires) ->
        if DateTime.compare(DateTime.utc_now(), expires) == :gt do
          {:error, "This invite code has expired."}
        else
          check_remaining_uses(ic)
        end

      ic ->
        check_remaining_uses(ic)
    end
  end

  @doc """
  Consumes an invite code (increments use_count). Returns {:ok, code} or {:error, reason}.

  `validate_code/1` is still run first for the specific, user-facing error
  (unknown / inactive / expired / exhausted) — but that read is just a
  best-effort pre-check for messaging. The actual consumption below is a
  single atomic `update_all` guarded by `use_count < max_uses`, so two
  concurrent callers that both pass the pre-check (both saw use_count still
  under max) can't both win: only the request whose UPDATE the DB evaluates
  first, i.e. before the row's `use_count` is bumped, satisfies the WHERE
  clause. The loser sees 0 rows updated and gets an error, even though its
  in-memory read was stale.
  """
  def use_code(code) do
    case validate_code(code) do
      {:ok, ic} -> consume(ic)
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume(%InviteCode{id: id, max_uses: max_uses}) do
    {count, rows} =
      Repo.update_all(
        from(ic in InviteCode,
          where: ic.id == ^id and ic.active == true and ic.use_count < ^max_uses,
          select: ic
        ),
        inc: [use_count: 1]
      )

    case {count, rows} do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, "This invite code has reached its maximum uses."}
    end
  end

  @doc """
  Lists all invite codes, newest first.
  """
  def list_codes do
    Repo.all(
      from ic in InviteCode,
        order_by: [desc: ic.inserted_at],
        preload: [:created_by]
    )
  end

  @doc """
  Deactivates an invite code.
  """
  def deactivate_code(%InviteCode{} = code) do
    code
    |> InviteCode.changeset(%{active: false})
    |> Repo.update()
  end

  defp check_remaining_uses(%InviteCode{max_uses: max, use_count: count} = ic) do
    if count >= max do
      {:error, "This invite code has reached its maximum uses."}
    else
      {:ok, ic}
    end
  end

  defp generate_code do
    :crypto.strong_rand_bytes(8) |> Base.encode32(padding: false)
  end
end
