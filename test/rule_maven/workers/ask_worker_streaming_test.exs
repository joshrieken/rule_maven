defmodule RuleMaven.Workers.AskWorkerStreamingTest do
  # End-to-end streaming ask: a fake OpenAI-compatible endpoint (stood up on a
  # local port and wired in via the llm_proxy_url setting) answers the ask call
  # as a chunked SSE stream. Asserts the partial-answer broadcasts arrive while
  # the stream runs AND that the re-assembled final response flows through the
  # existing parse/persist/broadcast pipeline unchanged.
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.Games
  alias RuleMaven.Workers.AskWorker

  @answer "**Yes** — roll the d20 to determine the first player at the start of every round of play."

  defmodule FakeLLM do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)

      if req["stream"] do
        # The interactive ask op must carry OpenRouter throughput routing.
        send(:streaming_test_proc, {:stream_request, req})
        sse(conn)
      else
        # Non-stream ops on the ask path (normalize, critic…): echo a plain
        # text completion that doubles as the normalized question.
        json = %{
          "choices" => [
            %{
              "message" => %{"content" => "How is the first player picked?"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(json))
      end
    end

    defp sse(conn) do
      answer =
        "**Yes** — roll the d20 to determine the first player at the start of every round of play."

      full =
        Jason.encode!(%{
          answer: answer,
          verdict: "info",
          citations: [
            %{
              quote: "Roll the d20 to determine the first player.",
              page: 5,
              source: "Core rules"
            }
          ],
          followups: [],
          also_asked: []
        })

      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> send_chunked(200)

      deltas =
        full
        |> String.graphemes()
        |> Enum.chunk_every(12)
        |> Enum.map(&Enum.join/1)

      conn =
        Enum.reduce(deltas, conn, fn delta, conn ->
          event = %{"choices" => [%{"delta" => %{"content" => delta}, "finish_reason" => nil}]}
          {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")
          conn
        end)

      finish = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 900, "completion_tokens" => 120, "total_tokens" => 1020}
      }

      {:ok, conn} = chunk(conn, "data: #{Jason.encode!(finish)}\n\n")
      {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
      conn
    end
  end

  setup do
    Process.register(self(), :streaming_test_proc)

    {:ok, server} = Bandit.start_link(plug: FakeLLM, port: 0, ip: :loopback)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, _} = RuleMaven.Settings.put("llm_proxy_url", "http://127.0.0.1:#{port}")

    on_exit(fn ->
      # Settings row rolls back with the sandbox; just stop the server.
      Process.exit(server, :normal)
    end)

    {:ok, game} =
      Games.create_game(%{name: "StreamGame #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core rules",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, _doc} = Games.update_document(doc, %{status: "published"})

    Repo.insert!(%Games.Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: "[Page 5]\nRoll the d20 to determine the first player.",
      page_number: 1,
      embedding: Pgvector.new(List.duplicate(0.1, 768))
    })

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        question: "How is the first player picked?",
        answer: "Thinking...",
        user_id: nil
      })

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    %{game: game, ql: ql}
  end

  test "streams partial answers over PubSub, then the normal :ask_complete", %{
    game: game,
    ql: ql
  } do
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             AskWorker.perform(%Oban.Job{
               id: System.unique_integer([:positive]),
               args: %{
                 "game_id" => game.id,
                 "question_log_id" => ql.id,
                 "question" => ql.question,
                 "expansion_ids" => [],
                 "user_id" => nil,
                 "skip_pool" => true
               }
             })

    # The streamed request carried OpenRouter throughput routing.
    assert_received {:stream_request, req}
    assert req["provider"] == %{"sort" => "throughput"}
    assert req["stream_options"] == %{"include_usage" => true}

    # At least one partial arrived, and it's a prefix of the final answer
    # (verdict-prefix stripping happens only at final parse, so compare
    # against the raw streamed answer text).
    assert_received {:ask_partial, %{question_log_id: ql_id, text: partial}}
    assert ql_id == ql.id
    assert String.starts_with?(@answer, partial)

    # The re-assembled stream flowed through the normal completion pipeline.
    assert_received {:ask_complete, %{question_log_id: ql_id2, refused: false}}
    assert ql_id2 == ql.id

    updated = Games.get_question_log(ql.id)
    # The "info" verdict strips the model's "**Yes** —" lead and recapitalizes.
    assert updated.answer =~ "Roll the d20 to determine the first player"
    assert updated.cited_page == 5

    # Streamed usage landed in llm_logs (cost dashboard depends on it).
    import Ecto.Query

    log =
      Repo.one(
        from l in RuleMaven.LLM.Log,
          where: l.operation == "ask" and l.question_log_id == ^ql.id,
          limit: 1
      )

    refute is_nil(log)
    assert log.prompt_tokens == 900
    assert log.completion_tokens == 120
  end
end
