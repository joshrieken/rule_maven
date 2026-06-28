defmodule RuleMaven.Users.UserToken do
  @moduledoc """
  Hashed, expiring tokens for email-address confirmation.

  The raw token is mailed to the user; only its SHA-256 hash is stored. A token
  is valid for `@confirm_validity_days`. Currently the only context is
  `"confirm"`.
  """
  use Ecto.Schema
  import Ecto.Query

  @hash_algorithm :sha256
  @rand_size 32
  @confirm_validity_days 7

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :user, RuleMaven.Users.User

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc """
  Builds a confirmation token. Returns `{encoded_token, struct}` — the encoded
  (URL-safe) token is mailed; the struct (holding the hash) is persisted.
  """
  def build_email_token(user, context \\ "confirm") do
    raw = :crypto.strong_rand_bytes(@rand_size)
    hashed = :crypto.hash(@hash_algorithm, raw)

    {Base.url_encode64(raw, padding: false),
     %__MODULE__{token: hashed, context: context, sent_to: user.email, user_id: user.id}}
  end

  @doc """
  Query that resolves a *valid* (unexpired) confirmation token to its user.
  Returns `:error` if the encoded token is malformed.
  """
  def verify_email_token_query(encoded_token, context \\ "confirm") do
    case Base.url_decode64(encoded_token, padding: false) do
      {:ok, raw} ->
        hashed = :crypto.hash(@hash_algorithm, raw)
        cutoff = DateTime.add(DateTime.utc_now(), -@confirm_validity_days * 24 * 3600, :second)

        query =
          from t in __MODULE__,
            join: u in assoc(t, :user),
            where:
              t.token == ^hashed and t.context == ^context and t.inserted_at >= ^cutoff,
            select: u

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc "Query for all tokens belonging to a user in a context (for cleanup)."
  def by_user_and_contexts_query(user, contexts) do
    from t in __MODULE__, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
