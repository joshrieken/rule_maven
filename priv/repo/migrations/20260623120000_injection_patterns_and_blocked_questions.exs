defmodule RuleMaven.Repo.Migrations.InjectionPatternsAndBlockedQuestions do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :blocked, :boolean, default: false, null: false
    end

    create index(:questions_log, [:blocked])

    create table(:injection_patterns) do
      add :pattern, :string, null: false
      add :category, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:injection_patterns, [:pattern])
    create index(:injection_patterns, [:enabled])

    patterns = [
      # instruction override
      {"ignore all previous", "instruction_override"},
      {"ignore previous instructions", "instruction_override"},
      {"ignore your instructions", "instruction_override"},
      {"ignore the above instructions", "instruction_override"},
      {"ignore the system", "instruction_override"},
      {"disregard your instructions", "instruction_override"},
      {"disregard all previous", "instruction_override"},
      {"disregard previous instructions", "instruction_override"},
      {"forget your instructions", "instruction_override"},
      {"forget all previous", "instruction_override"},
      {"forget previous instructions", "instruction_override"},
      {"override your instructions", "instruction_override"},
      {"bypass your instructions", "instruction_override"},
      {"bypass your rules", "instruction_override"},
      {"cancel previous instructions", "instruction_override"},
      {"your new instructions", "instruction_override"},
      # role change
      {"you are now a", "role_change"},
      {"you are now an", "role_change"},
      {"you will now act as", "role_change"},
      {"i want you to act as", "role_change"},
      {"i need you to act as", "role_change"},
      {"pretend you are", "role_change"},
      {"pretend to be", "role_change"},
      {"roleplay as", "role_change"},
      {"role play as", "role_change"},
      {"impersonate", "role_change"},
      {"from now on you are", "role_change"},
      {"from now on act as", "role_change"},
      # prompt extraction
      {"system prompt", "prompt_extraction"},
      {"reveal your instructions", "prompt_extraction"},
      {"repeat your instructions", "prompt_extraction"},
      {"print your instructions", "prompt_extraction"},
      {"show your instructions", "prompt_extraction"},
      {"display your instructions", "prompt_extraction"},
      {"output your instructions", "prompt_extraction"},
      {"what are your instructions", "prompt_extraction"},
      {"what is your system prompt", "prompt_extraction"},
      {"tell me your instructions", "prompt_extraction"},
      {"output your system", "prompt_extraction"},
      {"your original instructions", "prompt_extraction"},
      {"your initial instructions", "prompt_extraction"},
      {"your base instructions", "prompt_extraction"},
      {"your hidden instructions", "prompt_extraction"},
      {"your secret instructions", "prompt_extraction"},
      # jailbreak
      {"jailbreak", "jailbreak"},
      {"dan mode", "jailbreak"},
      {"developer mode", "jailbreak"},
      {"god mode", "jailbreak"},
      {"unrestricted mode", "jailbreak"},
      {"evil mode", "jailbreak"},
      {"do anything now", "jailbreak"},
      {"break character", "jailbreak"},
      {"sudo mode", "jailbreak"},
      # token injection
      {"[inst]", "token_injection"},
      {"[/inst]", "token_injection"},
      {"<<sys>>", "token_injection"},
      {"<|im_start|>", "token_injection"},
      {"<|im_end|>", "token_injection"},
      {"<|system|>", "token_injection"},
      {"<|user|>", "token_injection"},
      {"[system]", "token_injection"},
      {"### instruction", "token_injection"},
      {"### system", "token_injection"},
      {"</s>", "token_injection"},
      # future behavior
      {"in all future responses", "future_behavior"},
      {"for the rest of this conversation", "future_behavior"},
      {"for all future responses", "future_behavior"},
      # authority spoofing
      {"your creator says", "authority_spoofing"},
      {"anthropic says", "authority_spoofing"},
      {"openai says", "authority_spoofing"},
      {"your developer says", "authority_spoofing"},
      {"your training says", "authority_spoofing"},
      {"as your administrator", "authority_spoofing"},
    ]

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(patterns, fn {pattern, category} ->
        %{pattern: pattern, category: category, enabled: true, note: nil,
          inserted_at: now, updated_at: now}
      end)

    execute(fn -> repo().insert_all("injection_patterns", rows) end, fn -> :ok end)
  end
end
