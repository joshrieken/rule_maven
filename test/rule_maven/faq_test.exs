defmodule RuleMaven.FaqTest do
  use RuleMaven.DataCase
  alias RuleMaven.{Faq, Games}

  setup do
    {:ok, game} = Games.create_game(%{name: "Test Game"})
    %{game: game}
  end

  test "create and list faqs", %{game: game} do
    {:ok, faq} =
      Faq.create_faq(%{
        game_id: game.id,
        canonical_question: "How many cards?",
        canonical_answer: "5 cards per player",
        source_qa_ids: [1, 2]
      })

    assert faq.status == "draft"
    assert faq.auto_approved == false

    faqs = Faq.list_faqs(game)
    assert length(faqs) == 1
  end

  test "approve and publish faq", %{game: game} do
    {:ok, faq} =
      Faq.create_faq(%{
        game_id: game.id,
        canonical_question: "Test Q",
        canonical_answer: "Test A",
        source_qa_ids: [1]
      })

    {:ok, published} = Faq.approve_faq(faq, nil)
    assert published.status == "published"

    published_faqs = Faq.list_published(game)
    assert length(published_faqs) == 1
  end

  test "discard faq", %{game: game} do
    {:ok, faq} =
      Faq.create_faq(%{
        game_id: game.id,
        canonical_question: "Discard me",
        canonical_answer: "Nope",
        source_qa_ids: [1]
      })

    {:ok, discarded} = Faq.discard_faq(faq)
    assert discarded.status == "discarded"
  end
end
