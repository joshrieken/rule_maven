defmodule RuleMaven.Audit.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_logs" do
    field :actor_username, :string
    field :action, :string
    field :target_type, :string
    field :target_id, :integer
    field :target_label, :string
    field :metadata, :map, default: %{}
    belongs_to :actor, RuleMaven.Users.User

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :actor_id,
      :actor_username,
      :action,
      :target_type,
      :target_id,
      :target_label,
      :metadata
    ])
    |> validate_required([:action])
  end
end
