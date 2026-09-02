# Состояние и отчёты. Статус хранится в state.json, исходники задач не двигаются.
#
# Все функции записи берут лок сами, а не полагаются на вызывающего: при
# параллельном прогоне сюда пишут несколько воркеров разом, и схема
# «jq в файл + mv» без лока теряет чужие обновления целиком (mv атомарен,
# но читал-то воркер старую версию).

crun_state_file() { printf '%s/state.json' "$(crun_state_dir "$1")"; }

crun_state_init() {
  local f; f=$(crun_state_file "$1")
  mkdir -p "$(dirname "$f")/logs" "$(dirname "$f")/compiled"
  [ -f "$f" ] || echo '{"tasks":{}}' > "$f"
}

crun_state_get() {
  jq -r --arg s "$2" '.tasks[$s].status // "pending"' "$(crun_state_file "$1")" 2>/dev/null
}

# $1 проект $2 sha $3 id $4 статус $5 исходник
crun_state_set() {
  local f tmp lk held=0; f=$(crun_state_file "$1"); tmp=$(mktemp -t crun-state)
  lk=$(crun_lock_dir "$1" state); crun_lock "$lk" && held=1
  jq --arg s "$2" --arg i "$3" --arg st "$4" --arg src "$5" \
     --arg at "$(date '+%Y-%m-%d %H:%M:%S')" \
     '.tasks[$s] = {id:$i, status:$st, source:$src, at:$at}' "$f" > "$tmp" && mv "$tmp" "$f"
  [ "$held" = "1" ] && crun_unlock "$lk"
  rm -f "$tmp"
}

crun_progress_file() { printf '%s/PROGRESS.md' "$(crun_state_dir "$1")"; }

crun_progress_add() {
  local f lk held=0; f=$(crun_progress_file "$1")
  lk=$(crun_lock_dir "$1" state); crun_lock "$lk" && held=1
  [ -f "$f" ] || printf '# Выполненные задачи\n\n' > "$f"
  printf -- '- **%s** — %s _(%s)_\n  %s\n' \
    "$2" "$3" "$(date '+%Y-%m-%d %H:%M')" "$4" >> "$f"
  [ "$held" = "1" ] && crun_unlock "$lk"
}

# Хвост прогресса для промпта следующей задачи.
crun_progress_tail() {
  local f; f=$(crun_progress_file "$1")
  [ -f "$f" ] || return 0
  tail -30 "$f"
}

# Копит требования по всем задачам в setup.json и перегенерирует SETUP.md.
# $1 проект $2 id задачи $3 JSON-массив needs_from_user
crun_needs_write() {
  local proj="$1" task="$2" needs="$3"
  local dir sj md tmp cmds body lk held=0
  dir=$(crun_state_dir "$proj"); sj="$dir/setup.json"; md="$dir/SETUP.md"
  mkdir -p "$dir"
  lk=$(crun_lock_dir "$proj" state); crun_lock "$lk" && held=1
  [ -f "$sj" ] || echo '{"items":[]}' > "$sj"

  # Дедупликация по паре "что + команда": одна и та же зависимость всплывает
  # в нескольких задачах, но в списке должна остаться одной строкой.
  tmp=$(mktemp -t crun-setup)
  jq --argjson new "$needs" --arg task "$task" --arg at "$(date '+%Y-%m-%d %H:%M')" '
    .items = ((.items // []) + ($new | map(. + {task:$task, at:$at})))
    | .items |= (group_by(((.what // "") + "\u0000" + (.command // ""))) | map(.[0]))
  ' "$sj" > "$tmp" && mv "$tmp" "$sj"

  # Только однострочные команды: сводка вверху — это «скопировать и выполнить».
  # Многострочные блоки (развёртывание, установка) склеиваются в ней в нечитаемую
  # кашу и всё равно приведены целиком в своём разделе ниже.
  cmds=$(jq -r '.items[] | select((.command // "") != "")
                | select((.command | contains("\n")) | not) | .command' "$sj" \
         | awk '!seen[$0]++')

  {
    printf '# Что нужно сделать вручную\n\n'
    printf 'Раннер не ставит зависимости, не ходит в сеть и не трогает секреты.\n'
    printf 'Здесь копится всё, о чём он просил по ходу работы. Выполните и запустите `crun` снова.\n\n'

    if [ -n "$cmds" ]; then
      printf '## Команды\n\n```bash\n%s\n```\n\n' "$cmds"
    fi

    for k in dependency env account manual; do
      case "$k" in
        dependency) title="Зависимости" ;;
        env)        title="Переменные окружения и секреты" ;;
        account)    title="Внешние сервисы и доступы" ;;
        manual)     title="Прочее" ;;
      esac
      body=$(jq -r --arg k "$k" '
        .items[] | select((.kind // "manual") == $k)
        | "### " + .what + "\n"
          + (if (.why // "") != "" then "\n" + .why + "\n" else "" end)
          + (if (.command // "") != "" then "\n```bash\n" + .command + "\n```\n" else "" end)
          + (if (.how // "") != "" then "\n" + .how + "\n" else "" end)
          + "\n_задача " + (.task // "?") + " · " + (.at // "") + "_\n"' "$sj")
      [ -n "$body" ] && printf '## %s\n\n%s\n' "$title" "$body"
    done
  } > "$md"

  [ "$held" = "1" ] && crun_unlock "$lk"
  printf '%s' "$md"
}

# $1 проект $2 id $3 причина $4 путь к логу $5 рабочий каталог задачи (по умолч. проект)
# Файл один на прогон, поэтому пишется под локом: иначе два упавших воркера
# оставили бы в нём половину одного отчёта и половину другого.
crun_failure_write() {
  local f lk work held=0
  work="${5:-$1}"; f="$(crun_state_dir "$1")/logs/LAST_FAILURE.md"
  lk=$(crun_lock_dir "$1" state); crun_lock "$lk" && held=1
  {
    printf '# Задача `%s` не выполнена\n\n' "$2"
    printf '**Когда:** %s\n\n**Причина:** %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$3"
    if [ -n "${4:-}" ] && [ -f "$4" ]; then
      printf '## Хвост лога\n\n```\n%s\n```\n' "$(tail -40 "$4")"
    fi
    printf '\n## Состояние рабочего дерева\n\n```\n%s\n```\n' \
      "$(cd "$work" && git status --short 2>/dev/null | head -30)"
  } > "$f"
  [ "$held" = "1" ] && crun_unlock "$lk"
  printf '%s' "$f"
}
