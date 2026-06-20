Postgrex.Types.define(
  RuleMaven.PostgresTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
