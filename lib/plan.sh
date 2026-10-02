# Декомпозиция задачи с участием человека и разбор открытых вопросов.
# Единственное место в раннере, где вопросы модели задаются живому человеку:
# дальше задачи выполняются автономно и любая неясность закрывается догадкой.

# Диалог идёт через управляющий терминал, а не через stdin: вызывающий цикл может
# читать из файла, и обычный read съел бы его строку. Без терминала (пайп, тест,
# CI) откатываемся на stdin и stderr — иначе режим просто не запустить.
CRUN_TTY=""
crun_ui_init() {
  if { : > /dev/tty; } 2>/dev/null; then CRUN_TTY=/dev/tty; else CRUN_TTY=""; fi
}

# printf в интерфейс диалога. Не в stdout: там ответ, его читает вызывающий.
crun_ui() {
  if [ -n "${CRUN_TTY:-}" ]; then printf "$@" > "$CRUN_TTY"; else printf "$@" >&2; fi
}

crun_ask_line() {
  local ans
  crun_ui '%s> %s' "$C_B" "$C_RESET"
  if [ -n "${CRUN_TTY:-}" ]; then IFS= read -r ans < "$CRUN_TTY" || ans=""
  else                            IFS= read -r ans || ans=""; fi
  printf '%s' "$ans"
}

# Показать вопрос и получить ответ. "-" = пусть решает исполнитель.
# Пустой ввод: вариант по умолчанию, а если его нет — зависит от $4:
# skip=1 (clarify) вернёт пустую строку и вопрос останется открытым,
# skip=0 (plan) отдаст решение исполнителю явно.
# $1 номер $2 всего $3 JSON вопроса $4 skip(1/0). stdout — ответ.
crun_ask_question() {
  local n="$1" total="$2" q="$3" skip="${4:-0}" text why def opts ans i=0
  text=$(printf '%s' "$q" | jq -r '.q')
  why=$(printf '%s' "$q" | jq -r '.why // empty')
  def=$(printf '%s' "$q" | jq -r '.default // empty')

  crun_ui '\n%s[%s/%s]%s %s\n' "$C_B" "$n" "$total" "$C_RESET" "$text"
  [ -n "$why" ] && crun_ui '      %s%s%s\n' "$C_DIM" "$why" "$C_RESET"

  opts=$(printf '%s' "$q" | jq -r '.options[]? // empty')
  if [ -n "$opts" ]; then
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      i=$((i+1))
      crun_ui '      %s%s)%s %s\n' "$C_B" "$i" "$C_RESET" "$o"
    done <<EOF
$opts
EOF
  fi

  if [ -n "$def" ]; then
    crun_ui '      %sEnter — «%s» · «-» — пусть решит исполнитель%s\n' \
      "$C_DIM" "$def" "$C_RESET"
  elif [ "$skip" = "1" ]; then
    crun_ui '      %sEnter — пропустить · «-» — пусть решит исполнитель%s\n' "$C_DIM" "$C_RESET"
  else
    crun_ui '      %sEnter или «-» — пусть решит исполнитель%s\n' "$C_DIM" "$C_RESET"
  fi

  ans=$(crun_ask_line)

  # Номер варианта вместо текста — обычный способ ответить, когда варианты показаны.
  case "$ans" in
    ''|'-') ;;
    *[!0-9]*) ;;
    *) if [ -n "$opts" ]; then
         local pick; pick=$(printf '%s' "$opts" | sed -n "${ans}p")
         [ -n "$pick" ] && ans="$pick"
       fi ;;
  esac

  case "$ans" in
    '-') printf 'на усмотрение исполнителя' ;;
    '')  if   [ -n "$def" ];   then printf '%s' "$def"
         elif [ "$skip" = "1" ]; then :
         else printf 'на усмотрение исполнителя'; fi ;;
    *)   printf '%s' "$ans" ;;
  esac
}

# Провести раунд вопросов целиком. $1 JSON-массив вопросов, $2 файл накопленных Q&A.
crun_ask_round() {
  local qs="$1" qa="$2" total n=0 one ans
  total=$(printf '%s' "$qs" | jq 'length')
  [ "$total" = "0" ] && return 0

  printf '\n%sВопросы планировщика%s %s(Enter — вариант по умолчанию, «-» — решит исполнитель)%s\n' \
    "$C_B" "$C_RESET" "$C_DIM" "$C_RESET"

  while [ "$n" -lt "$total" ]; do
    one=$(printf '%s' "$qs" | jq -c ".[$n]")
    n=$((n+1))
    ans=$(crun_ask_question "$n" "$total" "$one")
    jq -n --arg q "$(printf '%s' "$one" | jq -r '.q')" --arg a "$ans" \
      '{q:$q, a:$a}' >> "$qa"
  done
  printf '\n'
}

# Один вызов планировщика. stdout = JSON ответа.
# $1 проект $2 бриф $3 файл Q&A $4 бинарь $5 модель $6 раунд $7 всего раундов
crun_plan_call() {
  local proj="$1" brief="$2" qa="$3" bin="$4" model="$5" round="$6" rounds="$7"
  local settings body raw out qatext budget

  settings=$(mktemp -t crun-plan-settings)
  jq -n --slurpfile deny "$CRUN_HOME/config/deny.json" \
        --arg hook "$CRUN_HOME/hooks/guard-secrets.sh" \
    '{permissions:{defaultMode:"dontAsk", allow:["Read","Grep","Glob"], deny:$deny[0]},
      hooks:{PreToolUse:[{matcher:"Bash|Read|Edit|Write|Grep|Glob",
                          hooks:[{type:"command",command:$hook}]}]}}' > "$settings"

  qatext=""
  if [ -s "$qa" ]; then
    qatext=$(jq -r '"**В:** " + .q + "\n**О:** " + .a + "\n"' "$qa")
    qatext=$(printf '## Ответы владельца\n\n%s\n' "$qatext")
  fi

  # Последний раунд объявляем явно: иначе модель копит вопросы вместо разбора.
  local tail_note=""
  if [ "$round" -ge "$rounds" ]; then
    tail_note=$(printf 'Это последний раунд: вопросов больше не будет. Верни ready: true\nи готовый разбор, опираясь на ответы выше и разумные умолчания.\n')
  else
    tail_note=$(printf 'Раунд %s из %s. Нужны уточнения — верни ready: false с вопросами,\nиначе ready: true и разбор.\n' "$round" "$rounds")
  fi

  body=$(printf 'Разбери задачу владельца на задачи для раннера.\n\n## Формулировка\n\n%s\n\n%s\n%s' \
           "$brief" "$qatext" "$tail_note")

  budget=$(crun_cfg "$proj" planBudget 3)
  raw=$(cd "$proj" && crun_run_limited 600 "$bin" -p "$body" \
          --output-format json \
          --json-schema "$(cat "$CRUN_HOME/config/plan-schema.json")" \
          --permission-mode dontAsk \
          --settings "$settings" \
          --strict-mcp-config \
          --tools "Read,Grep,Glob" \
          --append-system-prompt "$(cat "$CRUN_HOME/prompts/plan.md")" \
          --model "$model" --effort "$(crun_cfg "$proj" planEffort xhigh)" \
          --max-budget-usd "$budget" 2>/dev/null)
  rm -f "$settings"

  [ -z "$raw" ] && return 1
  out=$(printf '%s' "$raw" | jq -r '.result // empty' 2>/dev/null)
  [ -z "$out" ] && return 1
  out=$(printf '%s' "$out" | sed '/^```/d')
  printf '%s' "$out" | jq -e '.ready != null' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# Префикс имён для новых задач: продолжаем ту схему, что уже в папке.
# Схема этапов T<этап>.<номер> → новый этап; иначе числовой префикс с шагом 10.
# $1 папка задач. stdout: "T4." или "030-" и т.п.
crun_task_prefix() {
  local tasks="$1" maxstage=0 maxnum=0 f base st n
  for f in "$tasks"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in README.md|_*) continue ;; esac
    st=$(printf '%s' "$base" | sed -n 's/^[Tt]\([0-9]\{1,\}\)\.[0-9]\{1,\}.*/\1/p')
    if [ -n "$st" ]; then
      [ "$((10#$st))" -gt "$maxstage" ] && maxstage=$((10#$st))
      continue
    fi
    n=$(printf '%s' "$base" | sed -n 's/^\([0-9]\{1,\}\).*/\1/p')
    [ -n "$n" ] && [ "$((10#$n))" -gt "$maxnum" ] && maxnum=$((10#$n))
  done

  if [ "$maxstage" -gt 0 ]; then printf 'T%s.' "$((maxstage+1))"
  else printf '%03d-' "$((maxnum+10))"; fi
}

# Записать одну задачу: файл в папке задач + готовый спек в кэше компиляции.
# Спек пишем сами, чтобы не платить за повторную компиляцию того, что уже
# структурировано, и чтобы критерии приёмки не потерялись на быстром пути.
# $1 проект $2 папка $3 JSON задачи $4 порядковый номер $5 префикс $6 файл Q&A
# $7 файл соответствия "индекс<TAB>id" для depends_on
crun_write_task() {
  local proj="$1" tasks="$2" t="$3" idx="$4" prefix="$5" qa="$6" map="$7"
  local title id file slug order sha spec deps ctx touches touchjson

  title=$(printf '%s' "$t" | jq -r '.title')
  slug=$(crun_slug "$title")
  case "$prefix" in
    T*) id="${prefix}${idx}"; file="$tasks/${id}-${slug}.md" ;;
    *)  # 10# обязательно: иначе bash читает "030" как восьмеричное.
        id=$(printf '%03d' $(( 10#${prefix%-} + (idx-1)*10 )))
        file="$tasks/${id}-${slug}.md" ;;
  esac
  printf '%s\t%s\n' "$idx" "$id" >> "$map"

  # depends_on приходят номерами задач этого же разбора — переводим в id.
  deps=$(printf '%s' "$t" | jq -r '.depends_on[]?' | while IFS= read -r d; do
           [ -n "$d" ] && awk -F'\t' -v i="$d" '$1==i{print $2}' "$map"
         done)
  local depsjson
  depsjson=$(printf '%s' "$deps" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  deps=$(printf '%s' "$deps" | tr '\n' ' ')

  touchjson=$(printf '%s' "$t" | jq -c '.touches // []')
  touches=$(printf '%s' "$touchjson" | jq -r '.[]' | tr '\n' ' ')

  {
    printf -- '---\n'
    printf 'title: %s\n' "$title"
    local v vt tk
    v=$(printf '%s' "$t" | jq -r '.verify // empty')
    vt=$(printf '%s' "$t" | jq -r '.verify_timeout // empty')
    tk=$(printf '%s' "$t" | jq -r '.ticket // empty')
    [ -n "$v" ]  && printf 'verify: %s\n' "$v"
    [ -n "$vt" ] && printf 'verify_timeout: %s\n' "$vt"
    [ -n "$tk" ] && printf 'ticket: %s\n' "$tk"
    printf -- '---\n\n'

    printf '# %s\n\n' "$title"
    [ -n "$deps" ] && printf '**Зависит от:** %s\n\n' "$deps"
    [ -n "$touches" ] && printf '**Правит:** %s\n\n' "$touches"

    printf '## Цель\n\n%s\n\n' "$(printf '%s' "$t" | jq -r '.goal')"

    printf '## Критерии приёмки\n\n'
    printf '%s' "$t" | jq -r '.acceptance[]? | "- [ ] " + .'
    printf '\n'

    ctx=$(printf '%s' "$t" | jq -r '.context // empty')
    [ -n "$ctx" ] && printf '## Контекст\n\n%s\n\n' "$ctx"

    ctx=$(printf '%s' "$t" | jq -r '.not_in_scope // empty')
    [ -n "$ctx" ] && printf '## Не входит в задачу\n\n%s\n\n' "$ctx"

    if [ -s "$qa" ]; then
      printf '## Решения владельца\n\n'
      printf '<!-- Собрано при декомпозиции: crun plan. Это ответы человека,\n'
      printf '     они важнее догадок исполнителя. -->\n\n'
      jq -r '"**В:** " + .q + "  \n**О:** " + .a + "\n"' "$qa"
    fi
  } > "$file"

  # Спек кладём в кэш под sha свежесозданного файла — компиляция возьмёт его готовым.
  sha=$(crun_sha "$file")
  order=$(crun_order_of "$file")
  spec="$(crun_state_dir "$proj")/compiled/$sha.json"
  mkdir -p "$(dirname "$spec")"
  printf '%s' "$t" | jq --arg s "$file" --arg h "$sha" --arg i "$id" --argjson o "$order" \
    --argjson deps "$depsjson" --argjson touches "$touchjson" --slurpfile qa "$qa" \
    '{title, goal, acceptance: (.acceptance // []), risk: (.risk // "medium"),
      verify: (.verify // null), verify_timeout: (.verify_timeout // null),
      ticket: (.ticket // null),
      depends_on: $deps, touches: $touches, open_questions: [],
      answers: ($qa | map({q, a})),
      _source: $s, _sha: $h, _id: $i, order: $o}' > "$spec"

  printf '%s' "$file"
}

# crun plan — декомпозиция с диалогом. $1 проект $2 папка задач $3 бриф $4 бинарь $5 модель
crun_plan_run() {
  local proj="$1" tasks="$2" brief="$3" bin="$4" model="$5"
  local rounds qa ready qs n total prefix map file created=0 t i
  local res=""

  # Созданные файлы — для отдельного коммита перед запуском (crun_plan_commit).
  CRUN_PLAN_FILES=""
  crun_ui_init
  rounds=$(crun_cfg "$proj" planRounds 3)
  qa=$(mktemp -t crun-plan-qa); : > "$qa"
  map=$(mktemp -t crun-plan-map); : > "$map"
  mkdir -p "$tasks"

  i=1
  while [ "$i" -le "$rounds" ]; do
    printf '\n%sРаунд %s/%s%s %sдумаю над задачей…%s\n' \
      "$C_B" "$i" "$rounds" "$C_RESET" "$C_DIM" "$C_RESET"
    res=$(crun_plan_call "$proj" "$brief" "$qa" "$bin" "$model" "$i" "$rounds") || {
      rm -f "$qa" "$map"; err "планировщик не ответил"; return 1; }

    local und; und=$(printf '%s' "$res" | jq -r '.understanding // empty')
    [ -n "$und" ] && printf '%s%s%s\n' "$C_DIM" "$und" "$C_RESET"

    ready=$(printf '%s' "$res" | jq -r '.ready')
    if [ "$ready" = "true" ]; then break; fi

    qs=$(printf '%s' "$res" | jq -c '.questions // []')
    [ "$(printf '%s' "$qs" | jq 'length')" = "0" ] && break
    crun_ask_round "$qs" "$qa"
    i=$((i+1))
  done

  total=$(printf '%s' "$res" | jq '.tasks | length' 2>/dev/null || echo 0)
  if [ -z "$total" ] || [ "$total" = "0" ] || [ "$total" = "null" ]; then
    # Раунды кончились, а разбора нет: делаем финальный вызов по уже собранным
    # ответам. Иначе диалог с человеком пропал бы впустую — худший исход из всех.
    printf '\n%sсобираю разбор по вашим ответам…%s\n' "$C_DIM" "$C_RESET"
    res=$(crun_plan_call "$proj" "$brief" "$qa" "$bin" "$model" "$((rounds+1))" "$rounds") || {
      rm -f "$qa" "$map"; err "планировщик не ответил"; return 1; }
    total=$(printf '%s' "$res" | jq '.tasks | length' 2>/dev/null || echo 0)
  fi
  if [ -z "$total" ] || [ "$total" = "0" ] || [ "$total" = "null" ]; then
    rm -f "$qa" "$map"; err "планировщик не вернул задач"; return 1
  fi

  prefix=$(crun_task_prefix "$tasks")
  printf '\n%sСоздаю задачи%s\n' "$C_B" "$C_RESET"
  n=0
  while [ "$n" -lt "$total" ]; do
    t=$(printf '%s' "$res" | jq -c ".tasks[$n]")
    n=$((n+1))
    file=$(crun_write_task "$proj" "$tasks" "$t" "$n" "$prefix" "$qa" "$map")
    CRUN_PLAN_FILES="$CRUN_PLAN_FILES$file
"
    created=$((created+1))
    printf '  %s✓%s %-40s %s%s%s\n' "$C_GRN" "$C_RESET" "$(basename "$file")" \
      "$C_DIM" "$(printf '%s' "$t" | jq -r '.verify // "без проверки"')" "$C_RESET"
  done

  # Показываем, что из этого пойдёт параллельно: это главный результат разметки
  # depends_on и touches, и увидеть его владелец должен сразу, а не в прогоне.
  local waves
  waves=$(awk -F'\t' '{ print $2 }' "$map" | while IFS= read -r wid; do
            [ -n "$wid" ] || continue
            wspec=$(ls "$(crun_state_dir "$proj")"/compiled/*.json 2>/dev/null \
                    | while IFS= read -r f; do
                        [ "$(jq -r '._id // empty' "$f")" = "$wid" ] && { printf '%s' "$f"; break; }
                      done)
            [ -n "$wspec" ] || continue
            printf '%s\t%s\n' "$wid" \
              "$(jq -r '(.depends_on // [])[]' "$wspec" | tr '\n' ' ')"
          done | crun_waves_line)
  [ -n "$waves" ] && [ "$created" -gt 1 ] && \
    printf '\n  %sпараллельно: %s%s\n' "$C_DIM" "$waves" "$C_RESET"

  printf '\n'
  ok "создано задач: $created · вопросов задано: $(jq -s 'length' "$qa" 2>/dev/null || echo 0)"
  say "  файлы:  ${tasks#$proj/}/"
  rm -f "$qa" "$map"
  return 0
}

# Что дальше после разбора — тот же нумерованный выбор, что у проекта и папки задач.
# Enter и всё, кроме «1», — «позже»: случайное нажатие не должно стоить прогона.
# 0 — запускать.
crun_pick_after_plan() {
  local choice
  printf '\n%sЧто дальше?%s\n\n' "$C_B" "$C_RESET" >&2
  printf '  %s1)%s Запустить задачи\n' "$C_B" "$C_RESET" >&2
  printf '  %s2)%s %sПозже — запуск командой crun%s\n' "$C_B" "$C_RESET" "$C_DIM" "$C_RESET" >&2
  printf '\n%sДействие [1-2]:%s ' "$C_B" "$C_RESET" >&2
  read -r choice || choice=""
  [ "$choice" = "1" ]
}

# Файлы задач из разбора коммитим отдельно и только их: иначе прогон упрётся
# в грязное дерево, а `git add -A` первой задачи утащил бы их в свой коммит.
# Коммит по путям не трогает чужие staged-правки. $1 проект; файлы — CRUN_PLAN_FILES.
crun_plan_commit() {
  local proj="$1" f out
  local files=()
  [ -d "$proj/.git" ] || return 0

  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    # Папка задач в .gitignore — коммитить нечего, дерево и так чистое.
    git -C "$proj" check-ignore -q -- "$f" 2>/dev/null && continue
    files+=("$f")
  done <<EOF
${CRUN_PLAN_FILES:-}
EOF
  [ "${#files[@]}" -gt 0 ] || return 0

  if out=$(git -C "$proj" add -- "${files[@]}" 2>&1 && \
           git -C "$proj" commit -q \
             -m "chore(tasks): add ${#files[@]} tasks from crun plan" -- "${files[@]}" 2>&1); then
    info "файлы задач закоммичены"
    return 0
  fi
  err "не удалось закоммитить файлы задач:"
  printf '%s\n' "$out" >&2
  return 1
}

# crun clarify — пройтись по открытым вопросам уже скомпилированных задач.
# Ответы кладутся в спек: файлы задач пользователя раннер не переписывает.
# $1 проект $2 фильтр по id (пусто = все невыполненные)
crun_clarify_run() {
  local proj="$1" only="${2:-}"
  local cdir spec id sha st qs total n one ans tmp answered=0 touched=0 digest

  crun_ui_init
  cdir="$(crun_state_dir "$proj")/compiled"
  [ -d "$cdir" ] || { err "нет скомпилированных задач — запустите crun compile"; return 1; }

  for spec in "$cdir"/*.json; do
    [ -f "$spec" ] || continue
    id=$(jq -r '._id // empty' "$spec"); sha=$(jq -r '._sha // empty' "$spec")
    [ -n "$id" ] || continue
    [ -n "$only" ] && [ "$id" != "$only" ] && continue

    st=$(crun_state_get "$proj" "$sha")
    [ "$st" = "done" ] && continue

    qs=$(jq -c '.open_questions // []' "$spec")
    total=$(printf '%s' "$qs" | jq 'length')
    [ "$total" = "0" ] && continue

    printf '\n%s%s%s  %s%s%s\n' "$C_B" "$id" "$C_RESET" "$C_DIM" "$(jq -r .title "$spec")" "$C_RESET"
    printf '%s%s вопрос(ов) · Enter — пропустить (останется открытым), «-» — решит исполнитель%s\n' \
      "$C_DIM" "$total" "$C_RESET"

    tmp=$(mktemp -t crun-clarify)
    n=0
    while [ "$n" -lt "$total" ]; do
      one=$(printf '%s' "$qs" | jq -c "{q: .[$n], why: \"\"}")
      n=$((n+1))
      ans=$(crun_ask_question "$n" "$total" "$one" 1)
      [ -n "$ans" ] && jq -n --arg q "$(printf '%s' "$qs" | jq -r ".[$((n-1))]")" \
        --arg a "$ans" '{q:$q, a:$a}' >> "$tmp"
    done

    if [ -s "$tmp" ]; then
      # Отвеченное уходит из open_questions в answers: исполнитель должен видеть
      # решение владельца, а не тот же вопрос с пометкой «спросить некого».
      local out; out=$(mktemp -t crun-spec)
      jq --slurpfile new "$tmp" '
        .answers = ((.answers // []) + ($new | map({q, a})))
        | .open_questions = [ .open_questions[]?
            | . as $q | select(($new | map(.q) | index($q)) == null) ]
      ' "$spec" > "$out" && mv "$out" "$spec"
      answered=$((answered + $(jq -s 'length' "$tmp")))
      touched=$((touched+1))
    fi
    rm -f "$tmp"
  done

  if [ "$answered" = "0" ]; then
    ok "открытых вопросов нет — отвечать нечего"
    return 0
  fi

  # Человекочитаемая сводка: спеки — служебный формат, в них никто не заглядывает.
  digest="$(crun_state_dir "$proj")/ANSWERS.md"
  {
    printf '# Ответы владельца по задачам\n\n'
    printf 'Собрано командой `crun clarify`. Подмешивается в промпт задачи при запуске.\n\n'
    for spec in "$cdir"/*.json; do
      [ -f "$spec" ] || continue
      [ "$(jq '(.answers // []) | length' "$spec")" = "0" ] && continue
      printf '## %s — %s\n\n' "$(jq -r ._id "$spec")" "$(jq -r .title "$spec")"
      jq -r '.answers[] | "**В:** " + .q + "  \n**О:** " + .a + "\n"' "$spec"
    done
  } > "$digest"

  printf '\n'
  ok "ответов записано: $answered · задач затронуто: $touched"
  say "  сводка: ${digest#$proj/}"
  return 0
}
