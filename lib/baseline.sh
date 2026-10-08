# Проверка на базе: verify задачи, прогнанная ДО её работы.
#
# Зачем. verify — гейт приёмки. Если команда красная уже на исходном коде (долг
# проекта: ошибки tsc, неотформатированные чужие файлы), задача провалится при
# любом качестве работы, а узнаём мы это только после оплаченного прогона. Хуже
# того, исполнитель начинает сам снимать базу через git stash / checkout --, а это
# и запрещено, и опасно: refs/stash общий для всех worktree.
#
# Поэтому раннер гоняет verify на базе сам и помнит результат в
# .claude-runner/baseline.json. Ключ — содержимое дерева (HEAD^{tree} плюс хэш
# незакоммиченного), а не коммит: одинаковый код даёт попадание в кэш, даже если
# коммит другой. Используется в трёх местах: после `crun plan` (красные verify
# возвращаются планировщику), перед запуском (красные задачи не запускаются и
# не тратят токены) и перед каждой задачей в её рабочем каталоге — у зависимых
# задач база другая, чем у HEAD на момент старта прогона.
#
# Состояния CRUN_BL_STATE:
#   green    зелёная на базе            red      красная — гейт
#   timeout  не уложилась — гейт        na       на базе не прогнать целиком:
#   none     verify нет                          нет путей/скриптов, их создаст задача
#   off      проверка выключена         optout   у задачи baseline: false
#   live     проверка живучестью        nogit    не git или нет коммитов
#   missing  нет команд в PATH          unknown  в кэше нет, а гонять не просили

CRUN_BL_STATE=""; CRUN_BL_RC=""; CRUN_BL_SECS=""; CRUN_BL_TAIL=""; CRUN_BL_WHY=""
CRUN_BL_KEY=""; CRUN_BL_COMMIT=""; CRUN_BL_CACHED=0; CRUN_BL_PROBE=""; CRUN_BL_ABSENT=""
CRUN_BL_VERIFY=""; CRUN_BL_AT=""; CRUN_BL_SINCE=""
CRUN_EVAL_PID=""

crun_baseline_file() { printf '%s/baseline.json' "$(crun_state_dir "$1")"; }

crun_hash12() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }

# Выключатель: флаг --no-baseline (через окружение — его видят и воркеры) или
# "baseline": false в .claude-runner.json. crun_cfg тут не годится: в jq
# `false // x` даёт x, и выключить было бы нельзя.
crun_baseline_enabled() {
  [ "${CRUN_NO_BASELINE:-0}" = "1" ] && { printf 'false'; return; }
  local cfg="$1/.claude-runner.json"
  [ -f "$cfg" ] || { printf 'true'; return; }
  jq -r 'if .baseline == false then "false" else "true" end' "$cfg" 2>/dev/null || printf 'true'
}

# Ключ содержимого рабочего каталога. Чистое дерево — HEAD^{tree}; грязное —
# плюс хэш диффа и неотслеживаемых файлов. Служебная папка раннера не в счёт.
crun_baseline_key() {
  local work="$1" tree h
  tree=$(git -C "$work" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null) || return 1
  if [ -z "$(crun_dirty "$work")" ]; then printf '%s' "$tree"; return 0; fi
  h=$( { git -C "$work" diff HEAD --binary -- . ':(exclude).claude-runner' 2>/dev/null
         git -C "$work" ls-files -o --exclude-standard -- . ':(exclude).claude-runner' 2>/dev/null \
           | while IFS= read -r f; do
               printf '%s %s\n' "$f" "$(git -C "$work" hash-object -- "$f" 2>/dev/null)"
             done
       } | shasum -a 256 | cut -c1-12)
  printf '%s+%s' "$tree" "$h"
}

# Короткая подпись базы для людей: "abc1234" или "abc1234 + незакоммиченное".
crun_baseline_commit() {
  local c; c=$(git -C "$1" rev-parse --short HEAD 2>/dev/null) || c="?"
  case "${2:-}" in *+*) printf '%s + незакоммиченное' "$c" ;; *) printf '%s' "$c" ;; esac
}

# Встроенные команды пакетных менеджеров: всё прочее после `pnpm`/`yarn` — имя
# скрипта из package.json.
crun_pm_builtin() {
  case "$1" in
    add|install|i|ci|update|up|upgrade|remove|rm|uninstall|link|unlink|import|rebuild|rb|\
    prune|fetch|exec|dlx|create|run|start|publish|pack|audit|outdated|list|ls|why|store|\
    root|bin|setup|init|env|config|patch|patch-commit|deploy|licenses|doctor|server|\
    recursive|info|node|workspace|workspaces|set|cache|dedupe|version|help) return 0 ;;
  esac
  return 1
}

# Что из verify на базе ещё не существует: относительные пути с "/" и скрипты
# package.json. Это не ошибка — путь или скрипт создаст сама задача (или задача,
# от которой она зависит), — но и прогнать такую команду на базе целиком нельзя.
# stdout — список через пробел, пусто = всё на месте.
crun_baseline_absent() {
  local work="$1" cmd="$2" stripped tok out="" scripts="" seg s fwas=""
  stripped=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -e "s/'[^']*'/ /g" -e 's/"[^"]*"/ /g')

  case "$-" in *f*) fwas=1 ;; esac
  set -f
  for tok in $stripped; do
    tok="${tok%[;),]}"
    case "$tok" in
      -*|@*|/*|../*|*=*|*'$'*|*'*'*|*'?'*|*'['*|*'>'*|*'<'*|*://*) continue ;;
      */*) ;;
      *) continue ;;
    esac
    tok="${tok#./}"; tok="${tok%/}"
    [ -n "$tok" ] || continue
    [ -e "$work/$tok" ] || out="$out $tok"
  done
  [ -n "$fwas" ] || set +f

  if [ -f "$work/package.json" ]; then
    scripts=$(jq -r '(.scripts // {}) | keys[]' "$work/package.json" 2>/dev/null)
    while IFS= read -r seg; do
      # `npm|pnpm|yarn run X`, `npm test`, голый `pnpm X` / `yarn X`, где X не встроенная.
      s=$(printf '%s' "$seg" | sed -E -n \
            's/^[[:space:]]*(npm|pnpm|yarn)[[:space:]]+run[[:space:]]+([A-Za-z0-9][A-Za-z0-9:._-]*).*/\2/p')
      [ -n "$s" ] || s=$(printf '%s' "$seg" | sed -E -n \
            's/^[[:space:]]*npm[[:space:]]+(test|t)([[:space:]].*)?$/test/p')
      if [ -z "$s" ]; then
        s=$(printf '%s' "$seg" | sed -E -n \
              's/^[[:space:]]*(pnpm|yarn)[[:space:]]+([A-Za-z0-9][A-Za-z0-9:._-]*).*/\2/p')
        [ -n "$s" ] && crun_pm_builtin "$s" && s=""
      fi
      [ -n "$s" ] || continue
      printf '%s\n' "$scripts" | grep -qxF -- "$s" || out="$out package.json:scripts.$s"
    done <<EOF
$(printf '%s\n' "$stripped" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')
EOF
  fi
  printf '%s' "${out# }"
}

# Часть verify, которую можно прогнать на базе. Если ничего не отсутствует —
# команда целиком. Иначе, для простой цепочки через && без кавычек и прочих
# операторов, — звенья без отсутствующего; так `tsc && eslint src/new-dir` всё
# равно покажет красный tsc. Пусто — на базе прогнать нечего.
# Наружу: CRUN_BL_ABSENT.
crun_baseline_probe() {
  local work="$1" cmd="$2" seg probe="" a hit
  CRUN_BL_ABSENT=$(crun_baseline_absent "$work" "$cmd")
  [ -n "$CRUN_BL_ABSENT" ] || { printf '%s' "$cmd"; return 0; }

  case "$cmd" in *"'"*|*'"'*|*'||'*|*';'*|*'('*|*'`'*) return 0 ;; esac
  case "$cmd" in *"
"*) return 0 ;; esac
  # Одиночный | (пайп) — тоже не простая цепочка.
  printf '%s' "$cmd" | sed 's/&&//g' | grep -q '|' && return 0

  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$seg" ] || continue
    hit=0
    for a in $CRUN_BL_ABSENT; do
      case "$a" in
        package.json:scripts.*)
          printf '%s' "$seg" | grep -qE "(^|[[:space:]])${a#package.json:scripts.}([[:space:]]|$)" && hit=1 ;;
        *) case " $seg " in *" $a "*|*" ./$a "*|*" $a/ "*|*" $a/"*) hit=1 ;; esac ;;
      esac
    done
    [ "$hit" = "1" ] && continue
    probe="${probe:+$probe && }$seg"
  done <<EOF
$(printf '%s\n' "$cmd" | awk '{ gsub(/&&/, "\n"); print }')
EOF
  printf '%s' "$probe"
}

# Запись кэша. Читается без лока (mv атомарен), пишется под локом.
crun_baseline_get() {
  local f; f=$(crun_baseline_file "$1")
  [ -f "$f" ] || return 1
  jq -ce --arg k "$2" '.entries[$k] // empty' "$f" 2>/dev/null
}

# Запись, годная как ответ: таймаут с меньшим сроком — не ответ для большего.
# $1 проект $2 ключ записи $3 текущий срок. stdout — запись.
crun_baseline_fresh() {
  local entry old
  entry=$(crun_baseline_get "$1" "$2") || return 1
  if [ "$(printf '%s' "$entry" | jq -r .rc)" = "124" ]; then
    old=$(printf '%s' "$entry" | jq -r '.timeout // 0')
    [ "$old" -ge "$3" ] 2>/dev/null || return 1
  fi
  printf '%s' "$entry"
}

# $1 проект $2 ключ записи $3 ключ дерева $4 рабочий каталог $5 команда $6 код
# $7 секунды $8 таймаут $9 источник $10 файл вывода
crun_baseline_put() {
  local proj="$1" ek="$2" key="$3" work="$4" cmd="$5" rc="$6" secs="$7" tmo="$8"
  local src="$9" outf="${10}"
  local state f lk held=0 tmp logrel tail commit
  state=$(crun_state_dir "$proj"); f=$(crun_baseline_file "$proj")
  mkdir -p "$state/logs"
  commit=$(git -C "$work" rev-parse HEAD 2>/dev/null)
  logrel="logs/baseline-$(crun_hash12 "$ek").log"
  { printf '$ %s\n# база %s · код %s · %sс · %s\n\n' "$cmd" "$key" "$rc" "$secs" "$src"
    cat "$outf" 2>/dev/null; } > "$state/$logrel"
  # Цвета терминала в хвосте не нужны: он идёт в JSON, SETUP.md и промпты.
  tail=$(tail -n 60 "$outf" 2>/dev/null | sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' | tail -c 4000)

  lk=$(crun_lock_dir "$proj" baseline); crun_lock "$lk" 60 && held=1
  jq -e '.entries' "$f" >/dev/null 2>&1 || printf '{"version":1,"entries":{}}\n' > "$f"
  tmp=$(mktemp -t crun-bl)
  if jq --arg ek "$ek" --arg key "$key" --arg c "$commit" --arg cmd "$cmd" \
        --argjson rc "$rc" --argjson secs "$secs" --argjson tmo "$tmo" --arg src "$src" \
        --arg log "$logrel" --arg tail "$tail" --argjson ts "$(date +%s)" \
        --arg at "$(date '+%Y-%m-%d %H:%M:%S')" '
       .entries[$ek] = {key:$key, commit:$c, dirty:($key | contains("+")), cmd:$cmd,
                        rc:$rc, ok:($rc == 0), timeout:$tmo, secs:$secs, at:$at, ts:$ts,
                        source:$src, log:$log, tail:$tail}
       | .entries |= (to_entries | sort_by(.value.ts // 0) | .[-200:] | from_entries)' \
        "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
  [ "$held" = "1" ] && crun_unlock "$lk"
  # Полные логи — только последние 50: это расходник, источник истины — JSON.
  ls -t "$state"/logs/baseline-*.log 2>/dev/null | tail -n +51 | while IFS= read -r x; do
    rm -f "$x"
  done
  return 0
}

# Разложить запись кэша в CRUN_BL_*. $1 JSON записи.
crun_baseline_load() {
  CRUN_BL_RC=$(printf '%s' "$1" | jq -r '.rc')
  CRUN_BL_SECS=$(printf '%s' "$1" | jq -r '.secs // 0')
  CRUN_BL_TAIL=$(printf '%s' "$1" | jq -r '.tail // ""')
  CRUN_BL_AT=$(printf '%s' "$1" | jq -r '.at // ""')
  case "$CRUN_BL_RC" in
    0)   CRUN_BL_STATE=green ;;
    124) CRUN_BL_STATE=timeout ;;
    *)   CRUN_BL_STATE=red ;;
  esac
}

# Главная функция. $1 проект $2 рабочий каталог (база) $3 файл спека (нужны verify и
# verify_timeout) $4 источник для журнала $5 режим: run — из кэша или прогнать,
# force — прогнать заново, cached — только кэш.
# 0 — задачу можно запускать, 1 — гейт (red/timeout). Прогресс — в stderr.
crun_baseline_check() {
  local proj="$1" work="$2" spec="$3" src="$4" mode="${5:-run}"
  local verify probe binpath vmiss vtmo ek entry lk held=0 t0 since outf rc secs

  CRUN_BL_STATE=""; CRUN_BL_RC=""; CRUN_BL_SECS=""; CRUN_BL_TAIL=""; CRUN_BL_WHY=""
  CRUN_BL_KEY=""; CRUN_BL_COMMIT=""; CRUN_BL_CACHED=0; CRUN_BL_PROBE=""; CRUN_BL_ABSENT=""
  CRUN_BL_AT=""
  verify=$(jq -r '.verify // empty' "$spec" 2>/dev/null)
  CRUN_BL_VERIFY="$verify"

  [ -n "$verify" ] || { CRUN_BL_STATE=none; return 0; }
  [ "$(crun_baseline_enabled "$proj")" = "true" ] || { CRUN_BL_STATE=off; return 0; }
  [ "$(jq -r 'if .baseline == false then "no" else "yes" end' "$spec" 2>/dev/null)" = "no" ] \
    && { CRUN_BL_STATE=optout; return 0; }
  # Живучесть на базе не гоняем: она держит порты и контейнеры, мешая соседним
  # слотам, а падение на базе обычно говорит об окружении, а не о коде.
  CRUN_BL_WHY=$(crun_verify_blocking "$verify") && { CRUN_BL_STATE=live; return 0; }
  CRUN_BL_WHY=""
  CRUN_BL_KEY=$(crun_baseline_key "$work") || { CRUN_BL_STATE=nogit; return 0; }
  CRUN_BL_COMMIT=$(crun_baseline_commit "$work" "$CRUN_BL_KEY")

  # Нет команды — путь dependency в crun_task_verify; при разрешённой установке
  # задача может поставить её сама.
  binpath=$(crun_project_bin_path "$work")
  vmiss=$(cd "$work" && crun_verify_missing "$verify" "$binpath")
  [ -n "$vmiss" ] && { CRUN_BL_STATE=missing; CRUN_BL_WHY="$vmiss"; return 0; }

  probe=$(crun_baseline_probe "$work" "$verify")
  CRUN_BL_ABSENT=$(crun_baseline_absent "$work" "$verify")
  [ -n "$probe" ] || { CRUN_BL_STATE=na; CRUN_BL_WHY="$CRUN_BL_ABSENT"; return 0; }
  [ "$probe" != "$verify" ] && CRUN_BL_PROBE="$probe"

  vtmo=$(crun_verify_timeout "$proj" "$spec" 0)
  ek="$CRUN_BL_KEY $(crun_hash12 "$probe")"
  t0=$(date +%s)

  # force — «не старше начала»: CRUN_BL_SINCE задаёт crun baseline на весь прогон
  # таблицы, чтобы одна и та же команда не гонялась заново у каждой задачи.
  since="${CRUN_BL_SINCE:-$t0}"
  if entry=$(crun_baseline_fresh "$proj" "$ek" "$vtmo") && \
     { [ "$mode" != "force" ] || [ "$(printf '%s' "$entry" | jq -r '.ts // 0')" -ge "$since" ]; }; then
    crun_baseline_load "$entry"; CRUN_BL_CACHED=1
  elif [ "$mode" = "cached" ]; then
    CRUN_BL_STATE=unknown; return 0
  else
    # Один прогон на (дерево, команда): соседний слот с той же базой ждёт и берёт
    # результат из кэша, а не гонит сборку второй раз.
    lk=$(crun_lock_dir "$proj" "bl-$(crun_hash12 "$ek")")
    crun_lock "$lk" $((vtmo + 120)) && held=1
    if entry=$(crun_baseline_fresh "$proj" "$ek" "$vtmo") && \
       { [ "$mode" != "force" ] || [ "$(printf '%s' "$entry" | jq -r '.ts // 0')" -ge "$since" ]; }; then
      crun_baseline_load "$entry"; CRUN_BL_CACHED=1
    else
      printf '%s  база %s: прогоняю `%s` (до %sс)…%s\n' "$C_DIM" "$CRUN_BL_COMMIT" \
        "$(printf '%s' "$probe" | tr '\n' ' ' | cut -c1-70)" "$vtmo" "$C_RESET" >&2
      outf=$(mktemp -t crun-blout)
      t0=$(date +%s)
      crun_eval_limited "$vtmo" "$work" "$binpath" "$probe" "$outf"; rc=$?
      secs=$(( $(date +%s) - t0 ))
      crun_baseline_put "$proj" "$ek" "$CRUN_BL_KEY" "$work" "$probe" "$rc" "$secs" "$vtmo" "$src" "$outf"
      rm -f "$outf"
      entry=$(crun_baseline_get "$proj" "$ek") && crun_baseline_load "$entry"
      if [ -z "$CRUN_BL_STATE" ]; then
        # Запись не легла (битый JSON, нет места) — решаем по коду возврата.
        CRUN_BL_RC=$rc; CRUN_BL_SECS=$secs
        case "$rc" in 0) CRUN_BL_STATE=green ;; 124) CRUN_BL_STATE=timeout ;; *) CRUN_BL_STATE=red ;; esac
      fi
    fi
    [ "$held" = "1" ] && crun_unlock "$lk"
  fi

  # Прогнали только часть — зелёная часть ещё не значит «зелёная команда».
  if [ "$CRUN_BL_STATE" = "green" ] && [ -n "$CRUN_BL_PROBE" ]; then
    CRUN_BL_STATE=na; CRUN_BL_WHY="$CRUN_BL_ABSENT"
  fi
  case "$CRUN_BL_STATE" in red|timeout) return 1 ;; esac
  return 0
}

# Убить прогон базы по Ctrl+C: он в своей группе процессов (crun_eval_limited),
# и SIGINT терминала до него не доходит.
crun_baseline_abort() {
  [ -n "${CRUN_EVAL_PID:-}" ] || return 0
  kill -TERM -"$CRUN_EVAL_PID" 2>/dev/null || kill -TERM "$CRUN_EVAL_PID" 2>/dev/null
  return 0
}

# Засеять кэш зелёным результатом verify после задачи: чаще всего это и есть
# база следующей задачи, и прогонять сборку второй раз незачем.
# $1 проект $2 рабочий каталог $3 спек $4 id $5 секунды $6 вывод проверки
crun_baseline_seed() {
  local proj="$1" work="$2" spec="$3" id="$4" secs="$5" vout="$6" verify key ek outf
  [ "$(crun_baseline_enabled "$proj")" = "true" ] || return 0
  verify=$(jq -r '.verify // empty' "$spec")
  [ -n "$verify" ] || return 0
  key=$(crun_baseline_key "$work") || return 0
  ek="$key $(crun_hash12 "$verify")"
  crun_baseline_get "$proj" "$ek" >/dev/null && return 0
  outf=$(mktemp -t crun-blseed)
  printf '%s\n' "$vout" > "$outf"
  crun_baseline_put "$proj" "$ek" "$key" "$work" "$verify" 0 "${secs:-0}" \
    "$(crun_verify_timeout "$proj" "$spec" 0)" "verify задачи $id" "$outf"
  rm -f "$outf"
  return 0
}

# Одна строка с итогом для предпросмотра. Читает CRUN_BL_*.
crun_baseline_line() {
  local c="${CRUN_BL_CACHED:-0}" from=""
  [ "$c" = "1" ] && from=" · из кэша"
  case "$CRUN_BL_STATE" in
    green)   printf '%s✓ база %s: зелёная (%s)%s%s' "$C_GRN" "$CRUN_BL_COMMIT" \
               "$(crun_fmt_time "${CRUN_BL_SECS:-0}")" "$from" "$C_RESET" ;;
    red)     printf '%s✗ база %s: красная, код %s%s%s%s' "$C_RED" "$CRUN_BL_COMMIT" \
               "$CRUN_BL_RC" "${CRUN_BL_PROBE:+ (часть \`$CRUN_BL_PROBE\`)}" "$from" "$C_RESET" ;;
    timeout) printf '%s✗ база %s: не уложилась в срок%s%s%s' "$C_RED" "$CRUN_BL_COMMIT" \
               "${CRUN_BL_PROBE:+ (часть \`$CRUN_BL_PROBE\`)}" "$from" "$C_RESET" ;;
    na)      if [ -n "$CRUN_BL_PROBE" ]; then
               printf '%s· база %s: целиком не прогнать (нет %s), остальное зелёное%s' \
                 "$C_DIM" "$CRUN_BL_COMMIT" "$CRUN_BL_WHY" "$C_RESET"
             else
               printf '%s· база: не прогнать — нет %s (создаст задача)%s' "$C_DIM" "$CRUN_BL_WHY" "$C_RESET"
             fi ;;
    live)    printf '%s↻ база: проверку живучестью на базе не гоняем%s' "$C_DIM" "$C_RESET" ;;
    missing) printf '%s· база: не прогнать — нет команд: %s%s' "$C_DIM" "$CRUN_BL_WHY" "$C_RESET" ;;
    unknown) printf '%s⋯ база %s: проверю перед стартом%s' "$C_DIM" "$CRUN_BL_COMMIT" "$C_RESET" ;;
    optout)  printf '%s· база: отключена в задаче (baseline: false)%s' "$C_DIM" "$C_RESET" ;;
    off)     printf '%s· база: проверка выключена%s' "$C_DIM" "$C_RESET" ;;
    nogit)   printf '%s· база: не git-репозиторий%s' "$C_DIM" "$C_RESET" ;;
    *)       : ;;
  esac
}

# Хвост вывода красной базы, по строке с отступом. $1 сколько строк.
crun_baseline_tail_lines() {
  printf '%s\n' "$CRUN_BL_TAIL" | grep -v '^[[:space:]]*$' | tail -n "${1:-3}" \
    | cut -c1-140 | sed 's/^/        /'
}

# Пункт SETUP для задачи, отложенной из-за красной базы. Читает CRUN_BL_*.
# $1 id $2 verify $3 исходник задачи
crun_baseline_needs() {
  local id="$1" cmd="$2" src="$3" part=""
  [ -n "$CRUN_BL_PROBE" ] && part=" (её часть \`$CRUN_BL_PROBE\`)"
  jq -n --arg id "$id" --arg cmd "$cmd" --arg src "$src" --arg c "$CRUN_BL_COMMIT" \
        --arg rc "$CRUN_BL_RC" --arg st "$CRUN_BL_STATE" --arg part "$part" \
        --arg tail "$(printf '%s\n' "$CRUN_BL_TAIL" | grep -v '^[[:space:]]*$' | tail -n 15)" '
    [{kind: "manual",
      what: ("Проверка красная ещё до начала работы: `" + $cmd + "`"),
      why:  ("Раннер прогнал verify" + $part + " на базе " + $c + ", до правок задачи "
             + $id + ", и получил "
             + (if $st == "timeout" then "таймаут" else "код " + $rc end)
             + ". С таким гейтом задача провалится при любом качестве работы, поэтому"
             + " Claude не запускался и токены не потрачены."
             + (if $tail != "" then "\n\n```\n" + $tail + "\n```" else "" end)),
      how:  ((if $st == "timeout"
              then "Если команде просто мало времени — поднимите verify_timeout в задаче"
                   + " или verifyTimeout в .claude-runner.json. Иначе либо"
              else "Либо" end)
             + " почините проверку на текущем коде отдельным коммитом, либо замените"
             + " verify в " + $src + " на команду, которую проект держит зелёной"
             + " (обязательные проверки из CI, CLAUDE.md или AGENTS.md). Проверить:"
             + " `crun baseline`, затем `crun`. Если verify опирается на то, что задача"
             + " создаст сама, поставьте в её frontmatter `baseline: false`.")}]'
}

# Блок «Проверка» для промпта задачи. Читает CRUN_BL_* после гейта в crun_run_one.
crun_baseline_prompt() {
  local verify="$1"
  [ -n "$verify" ] || return 0
  printf '**Проверка:** после работы раннер выполнит `%s`.' "$verify"
  case "$CRUN_BL_STATE" in
    green)
      printf ' Перед стартом он уже прогнал её на базовом коммите `%s` — она **зелёная**.\n' "$CRUN_BL_COMMIT"
      printf 'Значит, любое её падение после твоей работы вызвано твоими правками: ищи причину\n'
      printf 'в своём диффе (`git diff`). Снимать базу самому (git stash, git checkout --,\n'
      printf 'откат правок) не нужно и нельзя.\n' ;;
    na)
      printf ' На базе `%s` целиком её не прогнать: нет `%s` — это появится по ходу задачи.\n' \
        "$CRUN_BL_COMMIT" "$CRUN_BL_WHY"
      [ -n "$CRUN_BL_PROBE" ] && \
        printf 'Остальная часть (`%s`) на базе зелёная — её падение будет вызвано твоими правками.\n' \
          "$CRUN_BL_PROBE"
      printf 'Убедись, что команда проходит целиком.\n' ;;
    *)
      printf ' Убедись, что проходит.\n' ;;
  esac
}

# Строка для попытки исправления: на базе было зелено — значит, сломала задача.
crun_baseline_fix_line() {
  case "$CRUN_BL_STATE" in
    green) printf '**База:** на `%s`, от которого ты начал, эта команда была зелёной — причина падения в твоём диффе (`git diff`).\n\n' "$CRUN_BL_COMMIT" ;;
    na)    [ -n "$CRUN_BL_PROBE" ] && \
             printf '**База:** на `%s` часть `%s` была зелёной; целиком команду на базе было не прогнать (нет `%s`).\n\n' \
               "$CRUN_BL_COMMIT" "$CRUN_BL_PROBE" "$CRUN_BL_WHY" ;;
  esac
  return 0
}

# Готова ли задача по зависимостям: все depends_on выполнены. $1 спек $2 idmap
# ("id\tстатус", см. crun_q_build_idmap). stdout — незакрытые зависимости.
crun_baseline_pending_deps() {
  local d out=""
  for d in $(jq -r '(.depends_on // [])[]' "$1"); do
    awk -F'\t' -v i="$d" '$1 == i && $2 == "done" { f = 1 } END { exit !f }' "$2" 2>/dev/null \
      || out="$out $d"
  done
  printf '%s' "${out# }"
}

# Перед запуском: прогнать базу у готовых задач (все зависимости выполнены).
# Каждая уникальная команда — один раз, остальное из кэша. Красные — в $5.
# $1 проект $2 очередь спеков $3 --only $4 idmap $5 файл отложенных
crun_baseline_prelaunch() {
  local proj="$1" queue="$2" only="$3" idmap="$4" pre="$5" s id sha shown=0
  : > "$pre"
  [ "$(crun_baseline_enabled "$proj")" = "true" ] || return 0
  git -C "$proj" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    id=$(jq -r ._id "$s"); sha=$(jq -r ._sha "$s")
    [ -n "$only" ] && [ "$id" != "$only" ] && continue
    [ "$(crun_state_get "$proj" "$sha")" = "done" ] && continue
    [ -n "$(jq -r '.verify // empty' "$s")" ] || continue
    [ -n "$(crun_baseline_pending_deps "$s" "$idmap")" ] && continue
    if [ "$shown" = "0" ]; then
      printf '%sПроверка verify на базе%s %s(до запуска, без модели)%s\n' \
        "$C_B" "$C_RESET" "$C_DIM" "$C_RESET" >&2
      shown=1
    fi
    crun_baseline_check "$proj" "$proj" "$s" "предзапуск" run || printf '%s\n' "$s" >> "$pre"
  done < "$queue"
  [ "$shown" = "1" ] && printf '\n' >&2
  return 0
}

# crun baseline: таблица по невыполненным задачам. Команды гоняются на текущем
# дереве; у задач с незакрытыми зависимостями настоящая база будет другой, это
# помечается. 1 — красная хотя бы у одной готовой задачи.
# $1 проект $2 очередь $3 --only $4 force(1/0)
crun_baseline_table() {
  local proj="$1" queue="$2" only="$3" force="$4" s id sha v deps mode rc=0
  local idmap n=0 ran=0 cached=0 key cmds
  idmap=$(mktemp -t crun-blidmap); crun_q_build_idmap "$proj" "$idmap"
  cmds=$(mktemp -t crun-blcmds); : > "$cmds"
  mode=run; [ "$force" = "1" ] && mode=force
  # Одна команда в одном прогоне таблицы — один раз, даже с --force.
  CRUN_BL_SINCE=$(date +%s)

  key=$(crun_baseline_key "$proj" 2>/dev/null) || key=""
  printf '\n%sПроверка verify на базе%s  %s%s%s\n\n' "$C_B" "$C_RESET" "$C_DIM" \
    "$([ -n "$key" ] && crun_baseline_commit "$proj" "$key" || printf 'не git')" "$C_RESET"

  while IFS= read -r s; do
    [ -n "$s" ] || continue
    id=$(jq -r ._id "$s"); sha=$(jq -r ._sha "$s")
    [ -n "$only" ] && [ "$id" != "$only" ] && continue
    [ "$(crun_state_get "$proj" "$sha")" = "done" ] && continue
    n=$((n+1))
    v=$(jq -r '.verify // empty' "$s")
    deps=$(crun_baseline_pending_deps "$s" "$idmap")
    crun_baseline_check "$proj" "$proj" "$s" "crun baseline" "$mode"
    case "$CRUN_BL_STATE:$CRUN_BL_PROBE" in green:*|red:*|timeout:*|na:?*)
      if ! grep -qxF -- "$v" "$cmds" 2>/dev/null; then
        printf '%s\n' "$v" >> "$cmds"
        [ "$CRUN_BL_CACHED" = "1" ] && cached=$((cached+1)) || ran=$((ran+1))
      fi ;;
    esac
    printf '  %-26s %s\n' "$id" "$(crun_baseline_line)"
    printf '      %sverify: %s%s\n' "$C_DIM" "$(printf '%s' "${v:-—}" | tr '\n' ' ' | cut -c1-90)" "$C_RESET"
    [ -n "$deps" ] && printf '      %sеё база — после %s: перед стартом проверю заново%s\n' \
      "$C_DIM" "$deps" "$C_RESET"
    case "$CRUN_BL_STATE" in
      red|timeout)
        crun_baseline_tail_lines 4
        [ -z "$deps" ] && rc=1 ;;
    esac
  done < "$queue"
  rm -f "$idmap" "$cmds"
  CRUN_BL_SINCE=""

  [ "$n" = "0" ] && { ok "нечего проверять — все задачи выполнены"; return 0; }
  printf '\n%sкоманд: %s · прогнано: %s · из кэша: %s · %s%s\n' "$C_DIM" \
    "$((ran + cached))" "$ran" "$cached" "$(crun_baseline_file "$proj")" "$C_RESET"
  [ "$rc" = "1" ] && warn "есть задачи, которые не запустятся: их verify красная ещё до работы"
  return $rc
}
