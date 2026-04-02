defmodule SpectreKinetic.ALExamples do
  @moduledoc false

  @spec action_defs() :: [map()]
  def action_defs do
    Enum.map(action_specs(), &build_action_def/1)
  end

  @spec examples() :: [map()]
  def examples do
    action_specs()
    |> Enum.flat_map(fn spec ->
      for index <- 1..100 do
        build_example(spec, index)
      end
    end)
  end

  defp action_specs do
    [
      %{
        tool_id: "Dynamic.Email.send/3",
        module: "Dynamic.Email",
        name: "send",
        arity: 3,
        action: "SEND OUTBOUND EMAIL",
        doc: "Send an outbound email message to an email recipient",
        spec: "send(to :: String.t(), subject :: String.t(), body :: String.t()) :: :ok",
        args: [
          arg("to", aliases: ["recipient", "email"]),
          arg("subject", aliases: ["title"]),
          arg("body", aliases: ["message", "text"])
        ]
      },
      %{
        tool_id: "Dynamic.Sms.send/2",
        module: "Dynamic.Sms",
        name: "send",
        arity: 2,
        action: "SEND OUTBOUND SMS",
        doc: "Send an outbound SMS message to a phone recipient",
        spec: "send(to :: String.t(), body :: String.t()) :: :ok",
        args: [
          arg("to", aliases: ["phone", "number", "recipient"]),
          arg("body", aliases: ["message", "text"])
        ]
      },
      %{
        tool_id: "Dynamic.Chat.post/2",
        module: "Dynamic.Chat",
        name: "post",
        arity: 2,
        action: "POST CHAT MESSAGE",
        doc: "Post a chat message into a channel or room",
        spec: "post(channel :: String.t(), body :: String.t()) :: :ok",
        args: [
          arg("channel", aliases: ["room"]),
          arg("body", aliases: ["message", "text"])
        ]
      },
      %{
        tool_id: "Dynamic.Article.write/2",
        module: "Dynamic.Article",
        name: "write",
        arity: 2,
        action: "WRITE KNOWLEDGE ARTICLE",
        doc: "Write a knowledge article with a title and body text",
        spec: "write(title :: String.t(), body :: String.t()) :: :ok",
        args: [
          arg("title", aliases: ["headline", "name"]),
          arg("body", aliases: ["text", "content"])
        ]
      },
      %{
        tool_id: "Dynamic.Note.insert/2",
        module: "Dynamic.Note",
        name: "insert",
        arity: 2,
        action: "INSERT NOTE ENTRY",
        doc: "Insert a note entry with title and body content",
        spec: "insert(title :: String.t(), body :: String.t()) :: :ok",
        args: [
          arg("title", aliases: ["name"]),
          arg("body", aliases: ["text", "content"])
        ]
      },
      %{
        tool_id: "Dynamic.Note.update/3",
        module: "Dynamic.Note",
        name: "update",
        arity: 3,
        action: "UPDATE NOTE ENTRY",
        doc: "Update a note entry identified by id",
        spec: "update(id :: String.t(), title :: String.t(), body :: String.t()) :: :ok",
        args: [
          arg("id", aliases: ["note_id"]),
          arg("title", aliases: ["name"], required: false),
          arg("body", aliases: ["text", "content"], required: false)
        ]
      },
      %{
        tool_id: "Dynamic.Note.delete/1",
        module: "Dynamic.Note",
        name: "delete",
        arity: 1,
        action: "DELETE NOTE ENTRY",
        doc: "Delete a note entry identified by id",
        spec: "delete(id :: String.t()) :: :ok",
        args: [
          arg("id", aliases: ["note_id"])
        ]
      },
      %{
        tool_id: "Dynamic.Task.create/3",
        module: "Dynamic.Task",
        name: "create",
        arity: 3,
        action: "CREATE WORK TASK",
        doc: "Create a work task with title due date and priority",
        spec: "create(title :: String.t(), due :: String.t(), priority :: String.t()) :: :ok",
        args: [
          arg("title", aliases: ["name"]),
          arg("due", aliases: ["deadline"]),
          arg("priority", aliases: ["severity"])
        ]
      },
      %{
        tool_id: "Dynamic.Task.update/3",
        module: "Dynamic.Task",
        name: "update",
        arity: 3,
        action: "UPDATE WORK TASK",
        doc: "Update a work task by id with status and assignee",
        spec: "update(id :: String.t(), status :: String.t(), assignee :: String.t()) :: :ok",
        args: [
          arg("id", aliases: ["task_id"]),
          arg("status", aliases: ["state"]),
          arg("assignee", aliases: ["owner"])
        ]
      },
      %{
        tool_id: "Dynamic.Task.delete/1",
        module: "Dynamic.Task",
        name: "delete",
        arity: 1,
        action: "DELETE WORK TASK",
        doc: "Delete a work task by id",
        spec: "delete(id :: String.t()) :: :ok",
        args: [
          arg("id", aliases: ["task_id"])
        ]
      }
    ]
  end

  defp build_action_def(spec) do
    %{
      id: spec.tool_id,
      module: spec.module,
      name: spec.name,
      arity: spec.arity,
      doc: spec.doc,
      spec: spec.spec,
      args: spec.args,
      examples:
        for index <- 1..5 do
          build_example(spec, index).al
        end
    }
  end

  defp build_example(%{action: "SEND OUTBOUND EMAIL"} = spec, index) do
    subject = ~s(Status #{index})
    body = ~s(Report #{index})

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(TO=user#{index}@example.com SUBJECT="#{subject}" BODY="#{body}"), %{
          "to" => "user#{index}@example.com",
          "subject" => subject,
          "body" => body
        })

      1 ->
        example(
          spec,
          ~s(RECIPIENT=ops#{index}@example.com TITLE="#{subject}" MESSAGE="#{body}"),
          %{
            "to" => "ops#{index}@example.com",
            "subject" => subject,
            "body" => body
          }
        )

      2 ->
        example(spec, ~s(EMAIL=team#{index}@example.com SUBJECT="#{subject}" TEXT="#{body}"), %{
          "to" => "team#{index}@example.com",
          "subject" => subject,
          "body" => body
        })

      3 ->
        example(spec, ~s(TO="user#{index}@example.com" SUBJECT="#{subject}" BODY="#{body}"), %{
          "to" => "user#{index}@example.com",
          "subject" => subject,
          "body" => body
        })

      _ ->
        example(
          spec,
          ~s(RECIPIENT=user#{index}@example.com SUBJECT="#{subject}" BODY="#{body}"),
          %{
            "to" => "user#{index}@example.com",
            "subject" => subject,
            "body" => body
          }
        )
    end
  end

  defp build_example(%{action: "SEND OUTBOUND SMS"} = spec, index) do
    phone = "+1555#{String.pad_leading(Integer.to_string(10_000 + index), 6, "0")}"
    body = "Code #{index}"

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(TO=#{phone} BODY="#{body}"), %{"to" => phone, "body" => body})

      1 ->
        example(spec, ~s(PHONE=#{phone} MESSAGE="#{body}"), %{"to" => phone, "body" => body})

      2 ->
        example(spec, ~s(NUMBER=#{phone} TEXT="#{body}"), %{"to" => phone, "body" => body})

      3 ->
        example(spec, ~s(RECIPIENT=#{phone} BODY="#{body}"), %{"to" => phone, "body" => body})

      _ ->
        example(spec, ~s(TO="#{phone}" MESSAGE="#{body}"), %{"to" => phone, "body" => body})
    end
  end

  defp build_example(%{action: "POST CHAT MESSAGE"} = spec, index) do
    channel = "room-#{rem(index, 12)}"
    body = "Chat #{index}"

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(CHANNEL=#{channel} BODY="#{body}"), %{
          "channel" => channel,
          "body" => body
        })

      1 ->
        example(spec, ~s(ROOM=#{channel} MESSAGE="#{body}"), %{
          "channel" => channel,
          "body" => body
        })

      2 ->
        example(spec, ~s(CHANNEL=#{channel} TEXT="#{body}"), %{
          "channel" => channel,
          "body" => body
        })

      3 ->
        example(spec, ~s(ROOM="#{channel}" BODY="#{body}"), %{
          "channel" => channel,
          "body" => body
        })

      _ ->
        example(spec, ~s(CHANNEL=#{channel} MESSAGE="#{body}"), %{
          "channel" => channel,
          "body" => body
        })
    end
  end

  defp build_example(%{action: "WRITE KNOWLEDGE ARTICLE"} = spec, index) do
    title = "Article #{index}"
    body = "Body #{index}"

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(TITLE="#{title}" BODY="#{body}"), %{"title" => title, "body" => body})

      1 ->
        example(spec, ~s(HEADLINE="#{title}" TEXT="#{body}"), %{"title" => title, "body" => body})

      2 ->
        example(spec, ~s(NAME="#{title}" CONTENT="#{body}"), %{"title" => title, "body" => body})

      3 ->
        example(spec, ~s(TITLE="#{title}" CONTENT="#{body}"), %{"title" => title, "body" => body})

      _ ->
        example(spec, ~s(HEADLINE="#{title}" BODY="#{body}"), %{"title" => title, "body" => body})
    end
  end

  defp build_example(%{action: "INSERT NOTE ENTRY"} = spec, index) do
    title = "Note #{index}"
    body = "Remember #{index}"

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(TITLE="#{title}" BODY="#{body}"), %{"title" => title, "body" => body})

      1 ->
        example(spec, ~s(NAME="#{title}" TEXT="#{body}"), %{"title" => title, "body" => body})

      2 ->
        example(spec, ~s(TITLE="#{title}" CONTENT="#{body}"), %{"title" => title, "body" => body})

      3 ->
        example(spec, ~s(NAME="#{title}" BODY="#{body}"), %{"title" => title, "body" => body})

      _ ->
        example(spec, ~s(TITLE="#{title}" TEXT="#{body}"), %{"title" => title, "body" => body})
    end
  end

  defp build_example(%{action: "UPDATE NOTE ENTRY"} = spec, index) do
    id = "note-#{index}"
    title = "Updated #{index}"
    body = "Rewritten #{index}"

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(ID=#{id} TITLE="#{title}" BODY="#{body}"), %{
          "id" => id,
          "title" => title,
          "body" => body
        })

      1 ->
        example(spec, ~s(NOTE_ID=#{id} NAME="#{title}" TEXT="#{body}"), %{
          "id" => id,
          "title" => title,
          "body" => body
        })

      2 ->
        example(spec, ~s(ID=#{id} NAME="#{title}" CONTENT="#{body}"), %{
          "id" => id,
          "title" => title,
          "body" => body
        })

      3 ->
        example(spec, ~s(NOTE_ID=#{id} TITLE="#{title}" CONTENT="#{body}"), %{
          "id" => id,
          "title" => title,
          "body" => body
        })

      _ ->
        example(spec, ~s(ID="#{id}" TITLE="#{title}" TEXT="#{body}"), %{
          "id" => id,
          "title" => title,
          "body" => body
        })
    end
  end

  defp build_example(%{action: "DELETE NOTE ENTRY"} = spec, index) do
    id = "note-#{index}"

    case rem(index - 1, 5) do
      0 -> example(spec, ~s(ID=#{id}), %{"id" => id})
      1 -> example(spec, ~s(NOTE_ID=#{id}), %{"id" => id})
      2 -> example(spec, ~s(ID="#{id}"), %{"id" => id})
      3 -> example(spec, ~s(NOTE_ID="#{id}"), %{"id" => id})
      _ -> example(spec, ~s(ID=#{id}), %{"id" => id})
    end
  end

  defp build_example(%{action: "CREATE WORK TASK"} = spec, index) do
    title = "Task #{index}"
    due = "2026-05-#{pad_day(index)}"
    priority = priority(index)

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(TITLE="#{title}" DUE=#{due} PRIORITY=#{priority}), %{
          "title" => title,
          "due" => due,
          "priority" => priority
        })

      1 ->
        example(spec, ~s(NAME="#{title}" DEADLINE=#{due} SEVERITY=#{priority}), %{
          "title" => title,
          "due" => due,
          "priority" => priority
        })

      2 ->
        example(spec, ~s(TITLE="#{title}" DEADLINE=#{due} PRIORITY=#{priority}), %{
          "title" => title,
          "due" => due,
          "priority" => priority
        })

      3 ->
        example(spec, ~s(NAME="#{title}" DUE=#{due} SEVERITY=#{priority}), %{
          "title" => title,
          "due" => due,
          "priority" => priority
        })

      _ ->
        example(spec, ~s(TITLE="#{title}" DUE=#{due} SEVERITY=#{priority}), %{
          "title" => title,
          "due" => due,
          "priority" => priority
        })
    end
  end

  defp build_example(%{action: "UPDATE WORK TASK"} = spec, index) do
    id = "task-#{index}"
    status = status(index)
    assignee = "user#{rem(index, 15)}"

    case rem(index - 1, 5) do
      0 ->
        example(spec, ~s(ID=#{id} STATUS=#{status} ASSIGNEE=#{assignee}), %{
          "id" => id,
          "status" => status,
          "assignee" => assignee
        })

      1 ->
        example(spec, ~s(TASK_ID=#{id} STATE=#{status} OWNER=#{assignee}), %{
          "id" => id,
          "status" => status,
          "assignee" => assignee
        })

      2 ->
        example(spec, ~s(ID=#{id} STATE=#{status} ASSIGNEE=#{assignee}), %{
          "id" => id,
          "status" => status,
          "assignee" => assignee
        })

      3 ->
        example(spec, ~s(TASK_ID=#{id} STATUS=#{status} OWNER=#{assignee}), %{
          "id" => id,
          "status" => status,
          "assignee" => assignee
        })

      _ ->
        example(spec, ~s(ID="#{id}" STATUS=#{status} ASSIGNEE=#{assignee}), %{
          "id" => id,
          "status" => status,
          "assignee" => assignee
        })
    end
  end

  defp build_example(%{action: "DELETE WORK TASK"} = spec, index) do
    id = "task-#{index}"

    case rem(index - 1, 5) do
      0 -> example(spec, ~s(ID=#{id}), %{"id" => id})
      1 -> example(spec, ~s(TASK_ID=#{id}), %{"id" => id})
      2 -> example(spec, ~s(ID="#{id}"), %{"id" => id})
      3 -> example(spec, ~s(TASK_ID="#{id}"), %{"id" => id})
      _ -> example(spec, ~s(ID=#{id}), %{"id" => id})
    end
  end

  defp example(spec, arg_string, expected_args) do
    %{
      al: "#{spec.action} WITH: #{arg_string}",
      tool_id: spec.tool_id,
      expected_args: expected_args
    }
  end

  defp arg(name, opts) do
    %{
      name: name,
      type: "String.t()",
      required: Keyword.get(opts, :required, true),
      aliases: Keyword.get(opts, :aliases, [])
    }
  end

  defp pad_day(index) do
    index
    |> rem(28)
    |> Kernel.+(1)
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  defp priority(index), do: Enum.at(["low", "medium", "high", "critical"], rem(index, 4))
  defp status(index), do: Enum.at(["open", "queued", "done", "in_progress"], rem(index, 4))
end
