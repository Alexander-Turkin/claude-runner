# Перевод задач из свободной формы в спек раннера. Исходники только читаются.

# Задачи в папке: *.md верхнего уровня и подпапки первого уровня (задача-папка:
# текст плюс картинки и прочие материалы). Служебное (_*, скрытое) пропускаем;
# папка без единого .md/.txt задачей не считается — это просто каталог с файлами.
crun_scan_tasks() {
  local d
  {
    find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
      | grep -v '/README\.md$' | grep -v '/_'
    find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '_*' 2>/dev/null \
      | while IFS= read -r d; do
          [ -n "$(crun_task_texts "$d" | head -1)" ] && printf '%s\n' "$d"
        done
  } | sort
}

# Материалы задачи-папки. Скрытые файлы не берём: .DS_Store и прочий мусор.
crun_task_all_files() {
  find "$1" -type f ! -path '*/.*' 2>/dev/null | LC_ALL=C sort
}

# Текст задачи: для файла — он сам, для папки — все .md/.txt в ней.
crun_task_texts() {
  if [ -d "$1" ]; then
    crun_task_all_files "$1" | grep -Ei '\.(md|txt)$'
  else
    printf '%s\n' "$1"
  fi
}

# Вложения задачи-папки (картинки, PDF, примеры данных) — абсолютными путями,
# JSON-массивом. У задачи-файла вложений нет.
crun_task_attachments() {
  if [ -d "$1" ]; then
    crun_task_all_files "$1" | grep -Eiv '\.(md|txt)$' \
      | jq -R -s -c 'split("\n") | map(select(length > 0))'
  else
    printf '[]'
  fi
}

# Файл, в котором ищем frontmatter: сама задача или первый по алфавиту .md папки.
crun_task_main() {
  if [ -d "$1" ]; then
    crun_task_all_files "$1" | grep -Ei '\.md$' | head -1
  else
    printf '%s' "$1"
  fi
}

# Код задачи из имени файла: T0.1 → "T0.1". Пусто, если такого префикса нет.
crun_code_of() {
  basename "$1" | sed -n 's/^\([Tt][0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/p'
}

# Порядок сортировки. Схема T<этап>.<номер> раскладывается в этап*1000 + номер*10,
# поэтому T0.1 < T0.2 < ... < T1.1. Иначе — ведущее число в имени, иначе 0.
crun_order_of() {
  local base maj min n
  base=$(basename "$1")
  maj=$(printf '%s' "$base" | sed -n 's/^[Tt]\([0-9]\{1,\}\)\.\([0-9]\{1,\}\).*/\1/p')
  min=$(printf '%s' "$base" | sed -n 's/^[Tt]\([0-9]\{1,\}\)\.\([0-9]\{1,\}\).*/\2/p')
  # 10# обязательно: иначе bash читает "010" как восьмеричное и порядок едет.
  if [ -n "$maj" ]; then printf '%s' $(( 10#$maj * 1000 + 10#$min * 10 )); return; fi
  n=$(printf '%s' "$base" | sed -n 's/^[^0-9]*\([0-9]\{1,\}\).*/\1/p')
  [ -n "$n" ] && printf '%s' $(( 10#$n )) || printf '0'
}

# Есть ли валидный frontmatter с title — тогда модель не нужна.
crun_has_frontmatter() {
  head -1 "$1" 2>/dev/null | grep -q '^---$' && \
  sed -n '2,20p' "$1" 2>/dev/null | grep -q '^title:[[:space:]]*[^[:space:]]'
}

crun_fm_get() {
  # Кавычки снимаются только когда обёрнуто ВСЁ значение. Срезать их по одной
  # с каждого конца нельзя: verify вида
  #   .venv/bin/python -c "import qrcode; print(qrcode.__version__)"
  # тогда теряет закрывающую кавычку и команда перестаёт парситься шеллом.
  sed -n '2,/^---$/p' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 \
    | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
}

# Список из одной строки frontmatter: "a, b c" → JSON-массив.
# Разделитель и запятая, и пробел: писать руками удобнее, чем YAML-список,
# а ошибиться труднее.
crun_fm_list() {
  crun_fm_get "$1" "$2" | tr ',' ' ' | tr -s ' ' '\n' \
    | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# Раздел markdown после frontmatter: строки между "## <заголовок>" и следующим "## ".
# $1 файл $2 заголовок без решёток.
crun_md_section() {
  awk -v h="## $2" '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm { if ($0 == "---") fm = 0; next }
    $0 == h { on = 1; next }
    on && /^## / { exit }
    on { print }' "$1"
}

# Пункты списка раздела → по одному в строке. Продолжения пункта (строки без
# маркера) приклеиваются к нему, чекбокс "[ ]" срезается.
crun_md_items() {
  awk '
    /^[[:space:]]*[-*][[:space:]]+/ {
      if (cur != "") print cur
      cur = $0
      sub(/^[[:space:]]*[-*][[:space:]]+(\[[ xX]\][[:space:]]+)?/, "", cur)
      next }
    /^[[:space:]]*$/ { if (cur != "") print cur; cur = ""; next }
    cur != "" { t = $0; sub(/^[[:space:]]+/, "", t); cur = cur " " t }
    END { if (cur != "") print cur }'
}

# Пары "**В:** …" / "**О:** …" раздела «Решения владельца» → "вопрос\tответ".
# sub(), а не substr(): кириллица многобайтная, а awk режет по байтам.
crun_md_answers() {
  awk '
    /<!--/ { com = 1 }
    com { if (/-->/) com = 0; next }
    /^\*\*В:\*\*/ { if (q != "") print q "\t" a; q = $0; a = ""; m = "q"
                       sub(/^\*\*В:\*\*[[:space:]]*/, "", q); next }
    /^\*\*О:\*\*/ { a = $0; m = "a"; sub(/^\*\*О:\*\*[[:space:]]*/, "", a); next }
    /^[[:space:]]*$/ { next }
    m == "q" { q = q " " $0; next }
    m == "a" { a = a " " $0; next }
    END { if (q != "") print q "\t" a }' | sed 's/[[:space:]]*\t/\t/; s/[[:space:]]*$//'
}

# Быстрый путь: собрать спек из frontmatter без вызова модели.
# Карточки от crun plan несут во frontmatter id, risk, depends_on и touches, а в теле —
# «Цель», «Критерии приёмки» и «Решения владельца»: их и разбираем, иначе ручная
# правка карточки (тот же verify) молча теряла бы критерии, ответы и зависимости.
crun_compile_frontmatter() {
  local src order="$2" title verify vtmo deps touches ticket risk bl goal acc ans
  src=$(crun_task_main "$1")
  title=$(crun_fm_get "$src" title)
  ticket=$(crun_fm_get "$src" ticket)
  verify=$(crun_fm_get "$src" verify)
  # Необязательный срок проверки: потолок ожидания для обычной команды,
  # длительность удержания — для проверки живучестью.
  vtmo=$(crun_fm_get "$src" verify_timeout)
  case "$vtmo" in ''|*[!0-9]*) vtmo="" ;; esac
  risk=$(crun_fm_get "$src" risk)
  case "$risk" in low|medium|high) ;; *) risk=low ;; esac
  # baseline: false — verify опирается на то, что создаст сама задача.
  bl=$(crun_fm_get "$src" baseline)
  # Зависимости и область правки: без них задача с frontmatter не смогла бы
  # участвовать в параллельном прогоне осмысленно.
  deps=$(crun_fm_list "$src" depends_on)
  touches=$(crun_fm_list "$src" touches)
  # Карточки старых версий crun plan держали их в теле.
  [ "$deps" = "[]" ] && deps=$(sed -n 's/^\*\*Зависит от:\*\*[[:space:]]*//p' "$src" | head -1 \
                                | tr ',' ' ' | tr -s ' ' '\n' | jq -R -s -c 'split("\n") | map(select(length > 0))')
  [ "$touches" = "[]" ] && touches=$(sed -n 's/^\*\*Правит:\*\*[[:space:]]*//p' "$src" | head -1 \
                                | tr ',' ' ' | tr -s ' ' '\n' | jq -R -s -c 'split("\n") | map(select(length > 0))')

  goal=$(crun_md_section "$src" "Цель")
  [ -n "$(printf '%s' "$goal" | tr -d '[:space:]')" ] || \
    goal=$(sed -n '/^---$/,/^---$/!p' "$src" | head -40 | tr '\n' ' ' | cut -c1-500)
  acc=$(crun_md_section "$src" "Критерии приёмки" | crun_md_items \
        | jq -R -s -c 'split("\n") | map(select(length > 0))')
  ans=$(crun_md_section "$src" "Решения владельца" | crun_md_answers \
        | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
                       | {q: .[0], a: (.[1] // "")})')

  jq -n --arg t "$title" --arg g "$goal" \
        --arg v "$verify" --arg vt "$vtmo" --arg tk "$ticket" --argjson o "$order" \
        --argjson d "$deps" --argjson tc "$touches" --arg rk "$risk" --arg bl "$bl" \
        --argjson acc "${acc:-[]}" --argjson ans "${ans:-[]}" \
    '{title:$t, order:$o, goal:($g | sub("^\\s+"; "") | sub("\\s+$"; "")),
      acceptance:$acc, risk:$rk,
      verify:(if $v == "" then null else $v end),
      verify_timeout:(if $vt == "" then null else ($vt | tonumber) end),
      ticket:(if $tk == "" then null else $tk end),
      depends_on:$d, touches:$tc, open_questions:[]}
     + (if ($ans | length) > 0 then {answers:$ans} else {} end)
     + (if $bl == "false" then {baseline:false} else {} end)'
}

# Компиляция одной задачи через модель. stdout = JSON спека.
crun_compile_model() {
  local proj="$1" src="$2" order="$3" bin="$4" model="$5"
  local settings raw body spec

  settings=$(mktemp -t crun-compile)
  jq -n --slurpfile deny "$CRUN_HOME/config/deny.json" \
        --arg hook "$CRUN_HOME/hooks/guard-secrets.sh" \
    '{permissions:{defaultMode:"dontAsk", allow:["Read","Grep","Glob"], deny:$deny[0]},
      hooks:{PreToolUse:[{matcher:"Bash|Read|Edit|Write|Grep|Glob",
                          hooks:[{type:"command",command:$hook}]}]}}' > "$settings"

  local att natt budget tmo=180 f
  budget=$(crun_cfg "$proj" compileBudget 10)
  att=$(crun_task_attachments "$src")
  natt=$(printf '%s' "$att" | jq 'length')

  if [ -d "$src" ]; then
    body=$(
      printf 'Скомпилируй эту задачу в спек.\n\nЗадача собрана из папки: %s\n' "$src"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '\n### %s\n\n---\n%s\n---\n' "${f#$src/}" "$(cat "$f")"
      done < <(crun_task_texts "$src")
      if [ "$natt" != "0" ]; then
        printf '\n## Материалы задачи\n\nПрочитай каждый файл инструментом Read — это часть постановки:\n\n'
        printf '%s' "$att" | jq -r '.[] | "- " + .'
        printf '\nТо, что видно на макетах и скриншотах (элементы, тексты, состояния), перенеси\nв критерии приёмки.\n'
      fi
    )
    # Картинки стоят времени: десяток макетов в таймаут обычной задачи не влезает.
    [ "$natt" != "0" ] && tmo=360
  else
    body=$(printf 'Скомпилируй эту задачу в спек.\n\nФайл: %s\n\n---\n%s\n---\n' \
             "$src" "$(cat "$src")")
  fi

  raw=$(cd "$proj" && crun_run_limited "$tmo" "$bin" -p "$body" \
          --output-format json \
          --json-schema "$(cat "$CRUN_HOME/config/compiled-schema.json")" \
          --permission-mode dontAsk \
          --settings "$settings" \
          --strict-mcp-config \
          --tools "Read,Grep,Glob" \
          --append-system-prompt "$(cat "$CRUN_HOME/prompts/compile.md")" \
          --model "$model" --effort "$(crun_cfg "$proj" planEffort xhigh)" \
          --max-budget-usd "$budget" 2>/dev/null)
  rm -f "$settings"

  [ -z "$raw" ] && return 1
  spec=$(crun_claude_output "$raw") || return 1
  # order задаёт имя файла, а не модель: её догадка ломает порядок этапов.
  printf '%s' "$spec" | jq -e --argjson o "$order" '.order = $o' 2>/dev/null || return 1
}

# Записать готовый спек и его читаемую копию. Общая часть быстрого пути
# (frontmatter) и модельного: иначе они разъезжаются при первой же правке.
# $1 проект $2 исходник $3 sha $4 order $5 код из имени $6 JSON спека
# stdout: id задачи.
crun_compile_write() {
  local proj="$1" src="$2" sha="$3" order="$4" code="$5" spec="$6"
  local cdir out id
  cdir="$(crun_state_dir "$proj")/compiled"; out="$cdir/$sha.json"

  if [ -n "$code" ]; then
    id="$code"
  else
    id=$(printf '%03d-%s' "$order" "$(crun_slug "$(printf '%s' "$spec" | jq -r .title)")")
  fi

  # Вложения — из файловой системы, а не из ответа модели: путь, который она
  # могла бы выдумать, исполнителю ни к чему.
  printf '%s' "$spec" | jq --arg s "$src" --arg h "$sha" --arg i "$id" --argjson o "$order" \
      --argjson a "$(crun_task_attachments "$src")" \
    '. + {_source:$s, _sha:$h, _id:$i, order:$o, attachments:$a}' > "$out.part" || return 1
  mv "$out.part" "$out" || return 1

  # Человекочитаемая копия — её и показываем в предпросмотре.
  {
    printf '# %s\n\n' "$(jq -r .title "$out")"
    printf '**Источник:** `%s`  \n**id:** `%s`  \n**Риск:** %s\n\n' \
      "$src" "$id" "$(jq -r .risk "$out")"
    printf '## Цель\n\n%s\n\n' "$(jq -r .goal "$out")"
    printf '## Критерии приёмки\n\n'; jq -r '.acceptance[]? | "- " + .' "$out"
    printf '\n## Проверка\n\n%s\n' "$(jq -r '.verify // "— не задана"' "$out")"
    if [ "$(jq -r '.attachments | length' "$out")" != "0" ]; then
      printf '\n## Материалы\n\n'; jq -r '.attachments[] | "- `" + . + "`"' "$out"
    fi
    if [ "$(jq -r '.open_questions | length' "$out")" != "0" ]; then
      printf '\n## Открытые вопросы\n\n'; jq -r '.open_questions[] | "- " + .' "$out"
    fi
  } > "$cdir/$sha.md.part" && mv "$cdir/$sha.md.part" "$cdir/$sha.md"

  printf '%s' "$id"
  return 0
}

# Один воркер компиляции: вызов модели плюс запись спека. Результат — в файл,
# потому что через границу подоболочки переменные обратно не проходят.
crun_compile_worker() {
  local proj="$1" src="$2" sha="$3" order="$4" code="$5" bin="$6" model="$7" res="$8"
  local spec t0 secs
  t0=$(date +%s)
  if ! spec=$(crun_compile_model "$proj" "$src" "$order" "$bin" "$model"); then
    printf 'fail\t%s\n' "$(( $(date +%s) - t0 ))" > "$res"; return 1
  fi
  if ! crun_compile_write "$proj" "$src" "$sha" "$order" "$code" "$spec" >/dev/null; then
    printf 'fail\t%s\n' "$(( $(date +%s) - t0 ))" > "$res"; return 1
  fi
  printf 'ok\t%s\n' "$(( $(date +%s) - t0 ))" > "$res"
  return 0
}

# Компилирует задачи.
# На экран идёт прогресс, а машинный список "<sha>\t<id>" пишется в файл $8:
# смешивать их в одном потоке нельзя — по списку строится очередь.
# Компиляция — платный вызов модели, поэтому берём только то, что реально нужно:
# выполненные пропускаем, --only и --limit сужают набор.
#
# Вызовы модели независимы и пишут каждый свой файл, поэтому идут пулом на $9
# воркеров: при десятке нескомпилированных задач это разница между минутой
# и десятью.
# $1 проект $2 папка $3 бинарь $4 модель $5 force $6 only-код $7 лимит
# $8 файл списка $9 потоков
crun_compile_dir() {
  local proj="$1" tasks="$2" bin="$3" model="$4" force="$5" only="${6:-}" limit="${7:-0}"
  local list="${8:-/dev/null}" jobs="${9:-1}"
  : > "$list"
  local state cdir src sha order spec out id code fid n=0 built=0
  local entries plan rdir
  state=$(crun_state_dir "$proj"); cdir="$state/compiled"
  mkdir -p "$cdir"

  # Порядок списка задаёт очередь прогона, поэтому фиксируем его сразу, до
  # параллельной части: результаты модели приходят вразнобой.
  entries=$(mktemp -t crun-centries); : > "$entries"
  plan=$(mktemp -t crun-cplan); : > "$plan"

  while IFS= read -r src; do
    [ -n "$src" ] || continue
    sha=$(crun_sha "$src")
    code=$(crun_code_of "$src")

    # Сузить набор до запрошенного.
    if [ -n "$only" ]; then
      case "$(basename "$src")" in "$only"*) ;; *) continue ;; esac
    fi
    # Уже выполненное перекомпилировать незачем.
    [ "$(crun_state_get "$proj" "$sha")" = "done" ] && continue

    # Лимит — это размер прогона, а не число обращений к модели.
    [ "$limit" != "0" ] && [ "$n" -ge "$limit" ] && break

    n=$((n+1))
    printf '%s\n' "$sha" >> "$entries"
    out="$cdir/$sha.json"
    order=$(crun_order_of "$src")

    # Кэш засчитывается, только если файл целый: прерывание на полуслове
    # (Ctrl+C) не должно оставлять огрызок, который потом примут за спек.
    if [ "$force" != "1" ] && [ -f "$out" ] && jq -e '._id' "$out" >/dev/null 2>&1; then
      printf '  %-34s %sиз кэша%s\n' "$(basename "$src")" "$C_DIM" "$C_RESET"
      continue
    fi
    rm -f "$out" "$cdir/$sha.md"

    built=$((built+1))
    if crun_has_frontmatter "$(crun_task_main "$src")"; then
      printf '  %-34s %sиз frontmatter%s\n' "$(basename "$src")" "$C_DIM" "$C_RESET"
      # id из frontmatter важнее имени файла: на него ссылаются depends_on соседей.
      fid=$(crun_fm_get "$(crun_task_main "$src")" id)
      case "$fid" in ''|*[!A-Za-z0-9._-]*) ;; *) code="$fid" ;; esac
      spec=$(crun_compile_frontmatter "$src" "$order")
      crun_compile_write "$proj" "$src" "$sha" "$order" "$code" "$spec" >/dev/null
    else
      # Дорогой путь: складываем в план и запускаем пулом ниже.
      printf '%s\t%s\t%s\t%s\n' "$src" "$sha" "$order" "$code" >> "$plan"
    fi
  done < <(crun_scan_tasks "$tasks")

  crun_compile_pool "$proj" "$plan" "$bin" "$model" "$jobs"

  # Список для очереди собираем по зафиксированному порядку. Спеки, которые
  # модель не осилила, отсеиваются сами: файла просто нет.
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    out="$cdir/$sha.json"
    [ -f "$out" ] || continue
    id=$(jq -r '._id // empty' "$out" 2>/dev/null)
    [ -n "$id" ] || continue
    printf '%s\t%s\n' "$sha" "$id" >> "$list"
  done < "$entries"

  rm -f "$entries" "$plan"
  [ "$n" = "0" ] && return 1
  return 0
}

# Пул компиляции по плану "<src>\t<sha>\t<order>\t<code>".
crun_compile_pool() {
  local proj="$1" plan="$2" bin="$3" model="$4" jobs="$5"
  local total k=0 running=0 rdir line
  local P_SRC P_SHA P_ORD P_CODE P_PID P_NAME
  total=$(grep -c . "$plan" 2>/dev/null | tr -d ' ')
  [ -z "$total" ] && total=0
  [ "$total" = "0" ] && return 0

  P_SRC=(); P_SHA=(); P_ORD=(); P_CODE=(); P_PID=(); P_NAME=()
  while IFS=$'\t' read -r a b c d; do
    [ -n "$a" ] || continue
    P_SRC[$k]="$a"; P_SHA[$k]="$b"; P_ORD[$k]="$c"; P_CODE[$k]="$d"
    P_NAME[$k]=$(basename "$a"); P_PID[$k]=""
    k=$((k+1))
  done < "$plan"

  rdir=$(mktemp -d -t crun-cpool)
  local started=0 finished=0 i
  while [ "$finished" -lt "$total" ]; do
    # запустить, пока есть места
    while [ "$started" -lt "$total" ] && [ "$running" -lt "$jobs" ]; do
      i=$started
      printf '  %-34s %sкомпилирую…%s\n' "${P_NAME[$i]}" "$C_DIM" "$C_RESET"
      crun_compile_worker "$proj" "${P_SRC[$i]}" "${P_SHA[$i]}" "${P_ORD[$i]}" \
        "${P_CODE[$i]}" "$bin" "$model" "$rdir/$i.res" &
      P_PID[$i]=$!
      started=$((started+1)); running=$((running+1))
    done

    # пожать завершившихся
    i=0
    while [ "$i" -lt "$started" ]; do
      if [ -n "${P_PID[$i]}" ] && ! kill -0 "${P_PID[$i]}" 2>/dev/null; then
        wait "${P_PID[$i]}" 2>/dev/null
        P_PID[$i]=""
        running=$((running-1)); finished=$((finished+1))
        if [ -s "$rdir/$i.res" ]; then
          IFS=$'\t' read -r a b < "$rdir/$i.res"
        else
          a=fail; b=0
        fi
        if [ "$a" = "ok" ]; then
          printf '  %-34s %s✓ готово (%sс)%s\n' "${P_NAME[$i]}" "$C_GRN" "$b" "$C_RESET"
        else
          printf '  %-34s %s✗ не удалось (%sс)%s\n' "${P_NAME[$i]}" "$C_RED" "$b" "$C_RESET"
        fi
      fi
      i=$((i+1))
    done
    [ "$finished" -lt "$total" ] && sleep 1
  done

  rm -rf "$rdir"
  return 0
}
