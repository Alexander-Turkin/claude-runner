# NDJSON от `claude --output-format stream-json --verbose` → строки для экрана.
# Одна строка события — одна строка вывода. Битые строки молча пропускаются:
# прогон не должен падать из-за мусора в потоке.

def trunc($n): if (. | length) > $n then (.[0:$n] + "…") else . end;
def base: split("/") | last;
def firstline: split("\n") | map(select(test("\\S"))) | (first // "") | gsub("^\\s+|\\s+$"; "");

# Цель инструмента одной строкой.
def target($n; $i):
  if $n == "Bash" then ($i.command // "" | gsub("\\s+"; " "))
  elif $n == "Grep" then (($i.pattern // "") + (if $i.path then " в " + ($i.path | base) else "" end))
  elif $n == "Glob" then ($i.pattern // "")
  elif $n == "Task" then ($i.description // "")
  elif $n == "WebFetch" or $n == "WebSearch" then ($i.url // $i.query // "")
  else (($i.file_path // $i.path // $i.notebook_path // "") | base)
  end;

fromjson? // empty
| if .type == "assistant" then
    (.message.content // [])[]
    | if .type == "tool_use" then
        .name as $n | (.input // {}) as $i
        | if $n == "TodoWrite" or $n == "StructuredOutput" or $n == "ExitPlanMode"
             or $n == "ToolSearch" then empty
          elif $n == "WebFetch" or $n == "WebSearch" then
            "\($blu)  ⇣\($reset) \(target($n; $i) | trunc($w))"
          elif $n == "Read" or $n == "Glob" or $n == "Grep" or $n == "NotebookRead" then
            "\($dim)  ⋯ \($n | .[0:6])\(" " * (7 - ($n | length | if . > 6 then 6 else . end)))\(target($n; $i) | trunc($w))\($reset)"
          elif $n == "Edit" or $n == "Write" or $n == "NotebookEdit" or $n == "MultiEdit" then
            "\($grn)  ✎\($reset) \($n | .[0:6])\(" " * (7 - ($n | length | if . > 6 then 6 else . end)))\(target($n; $i) | trunc($w))"
          elif $n == "Bash" then
            "\($blu)  $\($reset) \(target($n; $i) | trunc($w))"
          else
            "\($dim)  · \($n) \(target($n; $i) | trunc($w))\($reset)"
          end
      elif .type == "text" then
        (.text // "" | firstline) | select(length > 0)
        | "\($dim)  • \(. | trunc($w))\($reset)"
      # Блоки thinking приходят с пустым .thinking (есть только signature):
      # рассуждения зашифрованы и показать их нельзя. Видимость хода работы
      # обеспечивается репликами модели, которые просит писать prompts/system.md.
      else empty end

  # Отказ приходит как результат инструмента с ошибкой — показываем сразу,
  # не дожидаясь итогового permission_denials.
  elif .type == "user" then
    (.message.content // [])[]
    | select(.type == "tool_result" and (.is_error == true))
    | (if (.content | type) == "array" then (.content | map(.text // "") | join(" "))
       else (.content // "" | tostring) end | firstline)
    | select(length > 0)
    | if test("(?i)permission|denied|blocked|отклон") then
        "\($yel)  ⊘ \(. | trunc($w))\($reset)"
      else
        "\($dim)  ! \(. | trunc($w))\($reset)"
      end
  else empty end
