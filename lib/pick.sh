# Визуальный выбор проекта и папки задач.

CRUN_RECENT="$CRUN_HOME/recent.txt"

# Нативный диалог Finder. Пусто, если пользователь нажал Cancel или GUI недоступен.
crun_finder_pick() {
  osascript -e "POSIX path of (choose folder with prompt \"$1\")" 2>/dev/null \
    | sed 's:/$::'
}

crun_recent_add() {
  local p="$1" tmp
  tmp=$(mktemp -t crun-recent)
  printf '%s\n' "$p" > "$tmp"
  [ -f "$CRUN_RECENT" ] && grep -vxF "$p" "$CRUN_RECENT" 2>/dev/null | head -20 >> "$tmp"
  mv "$tmp" "$CRUN_RECENT"
}

# stdout = выбранный путь проекта
crun_pick_project() {
  local i=0 line choice sel
  local items=""

  if [ -f "$CRUN_RECENT" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ -d "$line" ] || continue
      i=$((i+1))
      items="$items$line
"
      printf '  %s%d)%s %s\n' "$C_B" "$i" "$C_RESET" "${line/#$HOME/~}" >&2
      [ "$i" -ge 10 ] && break
    done < "$CRUN_RECENT"
  fi

  i=$((i+1))
  printf '  %s%d)%s %sВыбрать другую папку…%s\n' "$C_B" "$i" "$C_RESET" "$C_DIM" "$C_RESET" >&2
  printf '\n%sПроект [1-%d]:%s ' "$C_B" "$i" "$C_RESET" >&2
  read -r choice

  if [ -z "$choice" ] || [ "$choice" = "$i" ]; then
    sel=$(crun_finder_pick "Выберите папку проекта")
    [ -z "$sel" ] && return 1
  else
    sel=$(printf '%s' "$items" | sed -n "${choice}p")
    [ -z "$sel" ] && return 1
  fi

  [ -d "$sel" ] || return 1
  printf '%s' "$sel"
}

# Папки-кандидаты: содержат хотя бы один *.md. stdout = выбранная папка.
crun_pick_tasks_dir() {
  local proj="$1" d cnt i=0 choice sel
  local items=""

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    cnt=$(find "$d" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
            | grep -v '/README\.md$' | grep -c . | tr -d ' ')
    [ "$cnt" = "0" ] && continue
    i=$((i+1))
    items="$items$d
"
    printf '  %s%d)%s %-32s %s%s задач%s\n' "$C_B" "$i" "$C_RESET" \
      "${d#$proj/}/" "$C_DIM" "$cnt" "$C_RESET" >&2
    [ "$i" -ge 12 ] && break
  done < <(find "$proj" -maxdepth 3 -type d \
             ! -path '*/node_modules*' ! -path '*/.git*' \
             ! -path '*/.claude-runner*' ! -path '*/dist*' ! -path '*/build*' \
             2>/dev/null | sort)

  i=$((i+1))
  printf '  %s%d)%s %sВыбрать другую папку…%s\n' "$C_B" "$i" "$C_RESET" "$C_DIM" "$C_RESET" >&2
  printf '\n%sПапка с задачами [1-%d]:%s ' "$C_B" "$i" "$C_RESET" >&2
  read -r choice

  if [ -z "$choice" ] || [ "$choice" = "$i" ]; then
    sel=$(crun_finder_pick "Выберите папку с задачами")
    [ -z "$sel" ] && return 1
  else
    sel=$(printf '%s' "$items" | sed -n "${choice}p")
    [ -z "$sel" ] && return 1
  fi

  [ -d "$sel" ] || return 1
  printf '%s' "$sel"
}
