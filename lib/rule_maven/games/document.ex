defmodule RuleMaven.Games.Document do
  use Ecto.Schema
  import Ecto.Changeset

  defmodule Page do
    @moduledoc """
    A single first-class rulebook page. `index` is the 0-based physical order,
    `sheet` the physical PDF sheet number, `printed` the rulebook's printed page
    number (nil when undetected).

    Two text layers (no markers): `text` is the read-only original from
    extraction, `cleaned` the editable working copy (auto-populated by Clean Up,
    then hand-editable; nil until cleaned/edited). The effective text used
    everywhere downstream is `cleaned || text`.

    Extraction provenance (nil on pre-existing pages): `confidence` is the
    quality-gate score 0.0–1.0, `lane` the ladder rung that produced the text
    ("text_layer" | "ocr" | "vision" | "ensemble"), `source` the winning reader.
    Low-confidence pages are surfaced for review and can be re-extracted a tier up.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :index, :integer
      field :sheet, :integer
      field :printed, :integer
      field :text, :string
      field :cleaned, :string
      field :confidence, :float
      field :lane, :string
      field :source, :string
      # Decision-log detail (Phase: per-source decision log). Captures *why* the
      # page landed where it did so the edit page can show the extraction
      # reasoning. nil for pages extracted before this was recorded, or where a
      # signal doesn't apply (e.g. gate signals on a clean-text-layer page).
      field :gate_agreement, :float
      field :gate_coverage, :float
      field :escalated, :boolean
      field :critic_rounds, :integer
      field :residual_defects, :integer
      # Cleanup critic's residual defect descriptions for the *current* cleaned
      # layer (distinct from `residual_defects`, the extraction critic's count).
      # Non-empty flags the page for review; each re-clean replaces the list.
      field :cleanup_defects, {:array, :string}
    end

    def changeset(page, attrs) do
      # empty_values: [] so a blank page body ("") is stored as "" rather than
      # Ecto's default of treating "" as missing and leaving the field nil.
      cast(
        page,
        attrs,
        [
          :index,
          :sheet,
          :printed,
          :text,
          :cleaned,
          :confidence,
          :lane,
          :source,
          :gate_agreement,
          :gate_coverage,
          :escalated,
          :critic_rounds,
          :residual_defects,
          :cleanup_defects
        ],
        empty_values: []
      )
    end
  end

  schema "documents" do
    field :label, :string
    field :full_text, :string
    field :pdf_path, :string
    field :html_path, :string
    field :source_url, :string
    field :content_type, :string
    field :file_size, :integer
    field :page_count, :integer
    field :printed_offset, :integer
    field :from_ocr, :boolean, default: false
    field :extracted_at, :utc_datetime
    field :status, :string, default: "pending_review"
    field :file_hash, :string
    # Marks this source as the game's core rulebook. When set, its label is
    # derived as "{Game Name} Core Rules" rather than inferred from the PDF.
    field :is_core, :boolean, default: false
    # Durable cleanup progress: pages persisted so far in the active run (nil
    # when idle). Updated incrementally by CleanupWorker so the UI counter is
    # reliable and survives refreshes.
    field :cleaning_done, :integer
    embeds_many :pages, Page, on_replace: :delete
    has_many :cheatsheet_versions, RuleMaven.CheatSheet.CheatSheetVersion
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :reviewed_by, RuleMaven.Users.User

    field :reviewed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :label,
      :full_text,
      :game_id,
      :pdf_path,
      :html_path,
      :source_url,
      :content_type,
      :file_size,
      :page_count,
      :printed_offset,
      :from_ocr,
      :extracted_at,
      :status,
      :file_hash,
      :is_core,
      :reviewed_by_id,
      :reviewed_at
    ])
    |> cast_embed(:pages, with: &Page.changeset/2)
    # full_text is absent for a source saved before extraction (ExtractWorker
    # fills it on demand); only label + game_id are required at ingest.
    |> validate_required([:label, :game_id])
  end
end

# Rulebook URLs reference documents by opaque token, never the raw id.
defimpl Phoenix.Param, for: RuleMaven.Games.Document do
  def to_param(%{id: id}), do: RuleMaven.Hashid.encode(id)
end
