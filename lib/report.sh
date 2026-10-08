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
# $1 проект $2 id задачи $3 JSON-массив needs_from_user $4 sha задачи $5 исходник
# задачи (необязательно: по ним пункты задачи убираются, когда она перезапускается
# или выполнена; исходник переживает правку карточки, sha — нет)
crun_needs_write() {
  local proj="$1" task="$2" needs="$3" sha="${4:-}" src="${5:-}"
  local dir sj md tmp lk held=0
  dir=$(crun_state_dir "$proj"); sj="$dir/setup.json"; md="$dir/SETUP.md"
  mkdir -p "$dir"
  lk=$(crun_lock_dir "$proj" state); crun_lock "$lk" && held=1
  [ -f "$sj" ] || echo '{"items":[]}' > "$sj"

  # Дедупликация по паре "что + команда": одна и та же зависимость всплывает
  # в нескольких задачах, но в списке должна остаться одной строкой.
  tmp=$(mktemp -t crun-setup)
  jq --argjson new "$needs" --arg task "$task" --arg sha "$sha" --arg src "$src" \
     --arg at "$(date '+%Y-%m-%d %H:%M')" '
    .items = ((.items // []) + ($new | map(. + {task:$task, at:$at}
                                           + (if $sha != "" then {sha:$sha} else {} end)
                                           + (if $src != "" then {source:$src} else {} end))))
    | .items |= (group_by(((.what // "") + "\u0000" + (.command // ""))) | map(.[0]))
  ' "$sj" > "$tmp" && mv "$tmp" "$sj"

  crun_needs_render "$proj"
  [ "$held" = "1" ] && crun_unlock "$lk"
  printf '%s' "$md"
}

# Убрать пункты задачи: она запускается заново, и прежние просьбы либо выполнены,
# либо всплывут снова. Без этого SETUP.md копил бы просьбы давно закрытых задач.
# $1 проект $2 id $3 sha $4 исходник
crun_needs_clear() {
  local proj="$1" id="$2" sha="${3:-}" src="${4:-}" sj tmp lk held=0
  sj="$(crun_state_dir "$proj")/setup.json"
  [ -f "$sj" ] || return 0
  lk=$(crun_lock_dir "$proj" state); crun_lock "$lk" && held=1
  tmp=$(mktemp -t crun-setup)
  # Свои — по исходнику: он переживает правку карточки, а sha нет. Пункты старых
  # версий раннера, без исходника, — по id.
  jq --arg id "$id" --arg src "$src" '
    .items |= map(select(
      if (.source // "") != "" and $src != "" then .source != $src
      else (.task // "") != $id end))
  ' "$sj" > "$tmp" && mv "$tmp" "$sj"
  rm -f "$tmp"
  crun_needs_render "$proj"
  [ "$held" = "1" ] && crun_unlock "$lk"
  return 0
}

# Убрать пункты выполненных задач (crun setup, crun status). Пункт без sha
# уходит, если его id выполнен и не числится ни за одной невыполненной задачей.
crun_needs_sweep() {
  local proj="$1" sj sf tmp lk held=0
  sj="$(crun_state_dir "$proj")/setup.json"; sf=$(crun_state_file "$proj")
  [ -f "$sj" ] && [ -f "$sf" ] || return 0
  lk=$(crun_lock_dir "$proj" state); crun_lock "$lk" && held=1
  tmp=$(mktemp -t crun-setup)
  jq --slurpfile st "$sf" '
    (($st[0].tasks // {})) as $t
    | ([$t[] | select(.status == "done") | .id]) as $done
    | ([$t[] | select(.status != "done") | .id]) as $open
    | .items |= map(select(
        if (.sha // "") != "" then (($t[.sha].status // "") != "done")
        else ((.task // "") as $id
              | (($done | index($id)) != null and ($open | index($id)) == null) | not)
        end))
  ' "$sj" > "$tmp" && mv "$tmp" "$sj"
  rm -f "$tmp"
  crun_needs_render "$proj"
  [ "$held" = "1" ] && crun_unlock "$lk"
  return 0
}

# SETUP.md из setup.json. Пусто — файла нет: его наличие и есть сигнал
# «нужно ваше участие» в crun status и в итоге прогона. Вызывать под локом state.
crun_needs_render() {
  local dir sj md cmds body k title
  dir=$(crun_state_dir "$1"); sj="$dir/setup.json"; md="$dir/SETUP.md"
  if [ ! -f "$sj" ] || [ "$(jq '(.items // []) | length' "$sj" 2>/dev/null)" = "0" ]; then
    rm -f "$md"; return 0
  fi

  # Только однострочные команды: сводка вверху — это «скопировать и выполнить».
  # Многострочные блоки (развёртывание, установка) склеиваются в ней в нечитаемую
  # кашу и всё равно приведены целиком в своём разделе ниже.
  cmds=$(jq -r '.items[] | select((.command // "") != "")
                | select((.command | contains("\n")) | not) | .command' "$sj" \
         | awk '!seen[$0]++')

  {
    printf '# Что нужно сделать вручную\n\n'
    printf 'Здесь — то, что раннер не может или не вправе сделать сам: секреты и доступы,\n'
    printf 'решения владельца, недостающие инструменты, проверки, красные ещё до начала задачи.\n'
    printf 'Выполните и запустите `crun` снова. Пункты задачи исчезают, когда она\n'
    printf 'перезапускается или выполняется.\n\n'

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
  return 0
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
