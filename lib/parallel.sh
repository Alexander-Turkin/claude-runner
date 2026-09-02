# Параллельное выполнение задач: изоляция через git worktree и планировщик по DAG.
#
# Почему worktree, а не общее рабочее дерево: verify — источник истины раннера,
# а в общем дереве проверка одной задачи видит недописанный код соседней и падает
# на ровном месте. Плюс `git add -A` одной задачи забрал бы правки другой в свой
# коммит, и «коммит на задачу» перестал бы быть точкой отката.

# ---------- worktree ----------

crun_wt_root()   { printf '%s/worktrees' "$(crun_state_dir "$1")"; }
crun_wt_path()   { printf '%s/w%s' "$(crun_wt_root "$1")" "$2"; }
crun_wt_branch() { printf 'crun/w%s' "$1"; }

# Окружение, которого нет в git, но без которого verify падает по 127:
# crun_project_bin_path ищет .venv/bin и node_modules/.bin.
# Симлинки, а не копии: .venv весит сотни мегабайт, копировать его на каждый слот
# перед каждой задачей дороже самой задачи.
#
# В умолчание намеренно не входят data/ и *.db: изменяемое состояние, общее для
# параллельных задач, — это гонка. Проекту, которому оно нужно, добавьте каталог
# в worktreeLink осознанно.
crun_wt_link() {
  local proj="$1" work="$2" names d
  names=$(crun_cfg_list "$proj" worktreeLink)
  if [ -z "$names" ]; then
    names='.venv
venv
env
node_modules
.env'
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # Только внутри проекта: симлинк наружу увёл бы задачу за границы доступа.
    case "$d" in /*|*..*) continue ;; esac
    [ -e "$proj/$d" ] || continue
    [ -e "$work/$d" ] && continue
    mkdir -p "$(dirname "$work/$d")" 2>/dev/null
    ln -s "$proj/$d" "$work/$d" 2>/dev/null
  done <<EOF
$names
EOF
  return 0
}

# PYTHONPATH против editable-install — без этого параллель тихо ломает verify.
#
# `pip install -e .` зашивает в .venv АБСОЛЮТНЫЙ путь к исходникам:
#   MAPPING: dict[str, str] = {'bot': '/Users/.../проект/bot'}
# С симлинком на .venv это значит, что pytest внутри worktree импортирует код
# ОСНОВНОГО дерева, а не правки задачи: проверка прошла бы, ничего не проверив.
#
# Лечится PYTHONPATH: install() ставит свой finder через sys.meta_path.append,
# то есть ПОСЛЕ штатного PathFinder, который читает sys.path, а записи PYTHONPATH
# попадают в sys.path раньше site-packages. Проверено замером на .venv проекта:
# порядок meta_path — BuiltinImporter, FrozenImporter, PathFinder, _EditableFinder.
crun_wt_pythonpath() {
  local proj="$1" work="$2" sp kind p d out="" tmp
  tmp=$(mktemp -t crun-pypath)
  for sp in "$proj"/.venv/lib/python*/site-packages \
            "$proj"/venv/lib/python*/site-packages \
            "$proj"/env/lib/python*/site-packages; do
    [ -d "$sp" ] || continue
    # setuptools >= 64: путь до самого пакета, в sys.path нужен его родитель.
    grep -ho ": '/[^']*'" "$sp"/__editable___*_finder.py 2>/dev/null \
      | sed "s/^: '//; s/'\$//" | sed 's/^/pkg	/' >> "$tmp"
    # Старый стиль: в .pth и .egg-link лежит уже готовая запись sys.path.
    cat "$sp"/*.egg-link "$sp"/*.pth 2>/dev/null \
      | grep '^/' | sed 's/^/dir	/' >> "$tmp"
  done

  while IFS=$'\t' read -r kind p; do
    [ -n "$p" ] || continue
    # Чужие пакеты трогать незачем — только исходники этого проекта.
    case "$p" in "$proj"/*) ;; *) continue ;; esac
    [ "$kind" = "pkg" ] && p=$(dirname "$p")
    case "$p" in
      "$proj") d="$work" ;;
      "$proj"/*) d="$work/${p#$proj/}" ;;
      *) continue ;;
    esac
    case ":$out:" in *":$d:"*) ;; *) out="${out:+$out:}$d" ;; esac
  done < "$tmp"
  rm -f "$tmp"
  printf '%s' "$out"
}

# Готовит слот к задаче и печатает путь к нему. Слот переиспользуется весь прогон:
# checkout каждый раз заново стоил бы дороже, чем сброс.
crun_wt_prepare() {
  local proj="$1" n="$2" wt br head
  wt=$(crun_wt_path "$proj" "$n"); br=$(crun_wt_branch "$n")
  head=$(git -C "$proj" rev-parse HEAD 2>/dev/null) || return 1

  if [ -e "$wt/.git" ]; then
    git -C "$wt" checkout -q -B "$br" "$head" 2>/dev/null || return 1
    git -C "$wt" reset -q --hard "$head" 2>/dev/null || return 1
    # Без -x: игнорируемые .venv/node_modules и симлинки на них должны выжить,
    # иначе каждый слот заново остаётся без окружения проекта.
    git -C "$wt" clean -qfd 2>/dev/null
  else
    rm -rf "$wt" 2>/dev/null
    mkdir -p "$(dirname "$wt")" 2>/dev/null
    git -C "$proj" worktree prune 2>/dev/null
    git -C "$proj" worktree add -q -B "$br" "$wt" "$head" 2>/dev/null || return 1
  fi
  crun_wt_link "$proj" "$wt"
  printf '%s' "$wt"
}

# Закоммитить работу задачи в ветке слота и влить в основную ветку.
# 0 — влито (или коммитить нечего), 1 — не удалось закоммитить, 2 — конфликт.
# $1 проект $2 слот $3 worktree $4 id $5 заголовок $6 summary
crun_wt_merge() {
  local proj="$1" n="$2" work="$3" id="$4" title="$5" summary="$6"
  local br lk rc=0
  br=$(crun_wt_branch "$n")

  # Код возврата `git add` здесь тоже не показатель (см. crun_wt_exclude):
  # смотрим на индекс, а не на него.
  git -C "$work" add -A -- . ':(exclude).claude-runner' 2>/dev/null
  git -C "$work" diff --cached --quiet 2>/dev/null && return 0
  git -C "$work" commit -q -m "task($id): $title" -m "$summary" 2>/dev/null || return 1

  # Мерж меняет основное рабочее дерево — строго по одному за раз.
  lk=$(crun_lock_dir "$proj" git); crun_lock "$lk" 600 || return 1
  if ! git -C "$proj" merge --no-edit -q "$br" 2>/dev/null; then
    git -C "$proj" merge --abort 2>/dev/null
    rc=2
  fi
  crun_unlock "$lk"
  return $rc
}

# Убрать слоты после прогона. Прерванный прогон слоты оставляет — следующий
# запуск их переиспользует, руками чистить ничего не нужно.
crun_wt_cleanup() {
  local proj="$1" jobs="${2:-0}" n=1 wt br
  [ -d "$proj/.git" ] || return 0
  while [ "$n" -le "$jobs" ]; do
    wt=$(crun_wt_path "$proj" "$n"); br=$(crun_wt_branch "$n")
    if [ -e "$wt" ]; then
      git -C "$proj" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt" 2>/dev/null
    fi
    git -C "$proj" branch -D "$br" 2>/dev/null
    n=$((n+1))
  done
  git -C "$proj" worktree prune 2>/dev/null
  rmdir "$(crun_wt_root "$proj")" 2>/dev/null
  return 0
}

# Можно ли в этом проекте вообще изолировать задачи. Печатает причину отказа.
# 0 — можно, 1 — нельзя (вызывающий откатывается на один поток).
crun_wt_check() {
  local proj="$1" jobs="$2" n=1 br
  [ -d "$proj/.git" ] || { printf 'не git-репозиторий'; return 1; }
  git -C "$proj" rev-parse HEAD >/dev/null 2>&1 || {
    printf 'в репозитории ещё нет коммитов'; return 1; }
  git -C "$proj" worktree list >/dev/null 2>&1 || {
    printf 'git не умеет worktree'; return 1; }

  # -B сбрасывает ветку. Если crun/wN уже существует и её коммиты не влиты,
  # это чужая работа — сброс уничтожил бы её молча.
  while [ "$n" -le "$jobs" ]; do
    br=$(crun_wt_branch "$n")
    if git -C "$proj" rev-parse --verify -q "$br" >/dev/null 2>&1; then
      git -C "$proj" merge-base --is-ancestor "$br" HEAD 2>/dev/null || {
        printf 'ветка %s содержит невлитые коммиты' "$br"; return 1; }
    fi
    n=$((n+1))
  done
  return 0
}

# ---------- зависимости и области правки ----------

# Глоб → префикс до первой звёздочки: "src/api/**" → "src/api/".
crun_touch_prefix() { printf '%s' "${1%%\**}"; }

# Пересекаются ли области двух задач. Пустой список = «область неизвестна»,
# такая задача совместима с любой: иначе все спеки, скомпилированные до
# появления touches, разом перестали бы идти параллельно.
# $1 и $2 — списки глобов, по одному в строке. 0 = пересекаются.
crun_touch_overlap() {
  local a="$1" b="$2" x y px py
  [ -n "$a" ] && [ -n "$b" ] || return 1
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    px=$(crun_touch_prefix "$x")
    while IFS= read -r y; do
      [ -n "$y" ] || continue
      py=$(crun_touch_prefix "$y")
      case "$px" in "$py"*) return 0 ;; esac
      case "$py" in "$px"*) return 0 ;; esac
    done <<EOF
$b
EOF
  done <<EOF
$a
EOF
  return 1
}

# Разбиение на волны по зависимостям: волна = глубина задачи в DAG. Показывается
# в предпросмотре и после crun plan, чтобы до запуска было видно, что пойдёт
# разом. Учитывает только depends_on: touches и число слотов влияют на факт,
# но не на потолок параллельности.
# stdin: "<id>\t<зависимости через пробел>"; stdout: "<волна>\t<id>"
crun_waves() {
  awk -F'\t' '
    { id[NR]=$1; dep[NR]=$2; n=NR }
    END {
      for (i = 1; i <= n; i++) w[id[i]] = 0
      # Зависимости вне набора игнорируем: они уже выполнены.
      for (pass = 0; pass < n; pass++) {
        changed = 0
        for (i = 1; i <= n; i++) {
          m = 0
          c = split(dep[i], d, " ")
          for (j = 1; j <= c; j++)
            if (d[j] in w && w[d[j]] + 1 > m) m = w[d[j]] + 1
          if (m > w[id[i]]) { w[id[i]] = m; changed = 1 }
        }
        if (!changed) break
      }
      for (i = 1; i <= n; i++) printf "%d\t%s\n", w[id[i]], id[i]
    }'
}

# Человекочитаемая строка «волна 1: A, B · волна 2: C» из того же входа.
crun_waves_line() {
  # cur = -1, а не "": awk сравнивает неинициализированную переменную с "0"
  # численно, и первая волна попала бы в ветку продолжения списка.
  crun_waves | sort -n -k1,1 | awk -F'\t' '
    BEGIN { cur = -1 }
    { if ($1 != cur) { if (NR > 1) printf " · "; cur = $1; printf "волна %d: %s", $1 + 1, $2 }
      else printf ", %s", $2 }
    END { if (NR > 0) printf "\n" }'
}

# Каталог со слотами — в локальный exclude репозитория: это чекауты всего
# проекта, и без этого `git status` у владельца был бы забит ими целиком.
# Пишем в .git/info/exclude, а не в .gitignore: файл пользователя не наш.
#
# Исключаем именно worktrees/, а не всю .claude-runner/: если игнорировать
# служебную папку целиком, `git add -A -- . ':(exclude).claude-runner'` начинает
# возвращать ошибку «paths are ignored» — файлы при этом добавляет, но по коду
# возврата задача выглядит провалившейся, и коммит не делается.
crun_wt_exclude() {
  local proj="$1" f line
  f="$proj/.git/info/exclude"
  line='.claude-runner/worktrees/'
  [ -d "$proj/.git" ] || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null
  [ -f "$f" ] && grep -qxF "$line" "$f" 2>/dev/null && return 0
  printf '%s\n' "$line" >> "$f" 2>/dev/null
  return 0
}

# ---------- планировщик прогона ----------

# Состояние прогона держим в глобальных массивах: bash 3.2 не умеет ни
# ассоциативные массивы, ни передачу массивов по имени.
CRUN_RUNDIR=""

crun_q_index_of() {
  local id="$1" k=0
  while [ "$k" -lt "$Q_N" ]; do
    [ "${T_ID[$k]}" = "$id" ] && { printf '%s' "$k"; return 0; }
    k=$((k+1))
  done
  return 1
}

# Карта "id -> статус" по всем скомпилированным спекам: зависимость может быть
# закрыта в прошлом прогоне и в текущую очередь не попасть.
crun_q_build_idmap() {
  local proj="$1" out="$2" cdir sf
  cdir="$(crun_state_dir "$proj")/compiled"; sf=$(crun_state_file "$proj")
  : > "$out"
  ls "$cdir"/*.json >/dev/null 2>&1 || return 0
  jq -r --slurpfile s "$sf" \
     '[(._id // empty), (($s[0].tasks[._sha // ""].status) // "pending")] | @tsv' \
     "$cdir"/*.json 2>/dev/null > "$out"
  return 0
}

crun_q_done_elsewhere() {
  awk -F'\t' -v i="$1" '$1 == i && $2 == "done" { f = 1 } END { print (f ? 1 : 0) }' \
    "$CRUN_RUNDIR/idmap" 2>/dev/null
}

# 0 — зависимости закрыты, 1 — ещё ждём, 2 — недостижимы.
crun_q_deps_state() {
  local i="$1" d j st waiting=0
  for d in ${T_DEPS[$i]}; do
    [ -n "$d" ] || continue
    if j=$(crun_q_index_of "$d"); then
      st="${T_ST[$j]}"
      case "$st" in
        done) ;;
        failed|blocked|skipped) return 2 ;;
        *) waiting=1 ;;
      esac
    else
      [ "$(crun_q_done_elsewhere "$d")" = "1" ] || return 2
    fi
  done
  [ "$waiting" = "1" ] && return 1
  return 0
}

# Первая незакрытая зависимость — для внятного сообщения о пропуске.
crun_q_bad_dep() {
  local i="$1" d j
  for d in ${T_DEPS[$i]}; do
    [ -n "$d" ] || continue
    if j=$(crun_q_index_of "$d"); then
      case "${T_ST[$j]}" in failed|blocked|skipped) printf '%s' "$d"; return 0 ;; esac
    else
      [ "$(crun_q_done_elsewhere "$d")" = "1" ] || { printf '%s' "$d"; return 0; }
    fi
  done
  return 1
}

# Мешает ли задаче хоть один из бегущих соседей.
crun_q_conflicts() {
  local i="$1" s j
  s=1
  while [ "$s" -le "$Q_JOBS" ]; do
    j="${W_TASK[$s]:--1}"
    if [ "$j" != "-1" ] && [ -n "${W_PID[$s]:-}" ]; then
      # Проверка живучестью занимает порты и имена контейнеров — она одна в прогоне.
      [ "${T_EXCL[$i]}" = "1" ] && return 0
      [ "${T_EXCL[$j]}" = "1" ] && return 0
      crun_touch_overlap "${T_TOUCH[$i]}" "${T_TOUCH[$j]}" && return 0
    fi
    s=$((s+1))
  done
  return 1
}

# Тело воркера. Локальные переменные crun_run_queue видны здесь по правилам
# динамической области видимости bash — отдельно их не передаём.
crun_q_worker() {
  local i="$1" work="$2" slot="$3" r
  crun_run_one "$Q_PROJ" "$work" "${T_SPEC[$i]}" "$Q_BIN" "$Q_MODEL" "$Q_BUDGET" \
               "$Q_TMO" "$Q_SETTINGS" "$Q_COMMIT" "$slot"
  r=$?
  printf '%s\t%s\t%s\t%s\n' "$r" "${CRUN_LAST_COST:-0}" "${CRUN_LAST_TURNS:-0}" \
    "${CRUN_LAST_SECS:-0}" > "$CRUN_RUNDIR/$i.res"
  return 0
}

# Новые строки лога воркера — на экран с пометкой, чья это задача.
crun_q_drain() {
  local slot="$1" i f seen total ln
  i="${W_TASK[$slot]}"
  f="$CRUN_RUNDIR/$i.out"
  [ -f "$f" ] || return 0
  seen=${W_SEEN[$slot]:-0}
  total=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  [ -z "$total" ] && total=0
  [ "$total" -gt "$seen" ] || return 0
  sed -n "$((seen+1)),${total}p" "$f" | while IFS= read -r ln; do
    printf '%s[%s]%s %s\n' "$C_DIM" "${T_ID[$i]}" "$C_RESET" "$ln"
  done
  W_SEEN[$slot]=$total
  return 0
}

crun_q_killall() {
  local s=1 p
  [ -n "$CRUN_RUNDIR" ] || return 0
  while [ "$s" -le "${Q_JOBS:-1}" ]; do
    p="${W_PID[$s]:-}"
    if [ -n "$p" ]; then
      kill -TERM -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
    fi
    s=$((s+1))
  done
  return 0
}

# Планировщик: держит до $jobs задач одновременно, стартуя каждую, как только
# закрыты её зависимости и освободилась область правки.
# $1 проект $2 файл очереди $3 бинарь $4 модель $5 бюджет $6 таймаут $7 settings
# $8 commit(1/0) $9 jobs $10 limit $11 continue-on-error $12 использовать worktree
# Наружу: CRUN_Q_DONE / BLOCK / FAIL / SKIP / COST / RC.
crun_run_queue() {
  Q_PROJ="$1"; local queue="$2"; Q_BIN="$3"; Q_MODEL="$4"; Q_BUDGET="$5"
  Q_TMO="$6"; Q_SETTINGS="$7"; Q_COMMIT="$8"; Q_JOBS="$9"
  local limit="${10}" keepgoing="${11}" usewt="${12}"
  local s spec i j st r cost turns secs started=0 stopping=0
  local running_now=0

  T_ID=(); T_SHA=(); T_SPEC=(); T_DEPS=(); T_TOUCH=(); T_ST=(); T_EXCL=()
  W_PID=(); W_TASK=(); W_SEEN=(); W_SLOTWT=()
  CRUN_Q_DONE=0; CRUN_Q_BLOCK=0; CRUN_Q_FAIL=0; CRUN_Q_SKIP=0; CRUN_Q_NOTRUN=0
  CRUN_Q_COST=0; CRUN_Q_RC=0

  Q_N=0
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    T_SPEC[$Q_N]="$spec"
    T_ID[$Q_N]=$(jq -r '._id' "$spec")
    T_SHA[$Q_N]=$(jq -r '._sha' "$spec")
    T_DEPS[$Q_N]=$(jq -r '(.depends_on // [])[]' "$spec" | tr '\n' ' ')
    T_TOUCH[$Q_N]=$(jq -r '(.touches // [])[]' "$spec")
    T_ST[$Q_N]=pending
    if crun_verify_blocking "$(jq -r '.verify // empty' "$spec")" >/dev/null; then
      T_EXCL[$Q_N]=1
    else
      T_EXCL[$Q_N]=0
    fi
    Q_N=$((Q_N+1))
  done < "$queue"
  [ "$Q_N" = "0" ] && return 0

  CRUN_RUNDIR=$(mktemp -d -t crun-run)
  crun_q_build_idmap "$Q_PROJ" "$CRUN_RUNDIR/idmap"

  s=1
  while [ "$s" -le "$Q_JOBS" ]; do W_PID[$s]=""; W_TASK[$s]=-1; W_SEEN[$s]=0; s=$((s+1)); done

  while :; do
    # 1. Показать, что успели написать бегущие воркеры.
    if [ "$Q_JOBS" != "1" ]; then
      s=1
      while [ "$s" -le "$Q_JOBS" ]; do
        [ -n "${W_PID[$s]}" ] && crun_q_drain "$s"
        s=$((s+1))
      done
    fi

    # 2. Пожать завершившихся.
    s=1
    while [ "$s" -le "$Q_JOBS" ]; do
      if [ -n "${W_PID[$s]}" ] && ! kill -0 "${W_PID[$s]}" 2>/dev/null; then
        wait "${W_PID[$s]}" 2>/dev/null
        i="${W_TASK[$s]}"
        [ "$Q_JOBS" != "1" ] && crun_q_drain "$s"
        r=1; cost=0; turns=0; secs=0
        if [ -s "$CRUN_RUNDIR/$i.res" ]; then
          IFS=$'\t' read -r r cost turns secs < "$CRUN_RUNDIR/$i.res"
        fi
        CRUN_Q_COST=$(printf '%s + %s\n' "$CRUN_Q_COST" "${cost:-0}" \
                      | bc -l 2>/dev/null || printf '%s' "$CRUN_Q_COST")
        case "$r" in
          0) T_ST[$i]=done; CRUN_Q_DONE=$((CRUN_Q_DONE+1))
             printf '%s✓%s %s · %s · $%.2f · %s шагов\n' "$C_GRN" "$C_RESET" \
               "${T_ID[$i]}" "$(crun_fmt_time "${secs:-0}")" "${cost:-0}" "${turns:-0}" ;;
          2) T_ST[$i]=blocked; CRUN_Q_BLOCK=$((CRUN_Q_BLOCK+1))
             warn "${T_ID[$i]}: нужно ваше участие — задача отложена"
             CRUN_Q_RC=2; [ "$keepgoing" = "1" ] || stopping=1 ;;
          *) T_ST[$i]=failed; CRUN_Q_FAIL=$((CRUN_Q_FAIL+1))
             err "${T_ID[$i]}: не выполнена"
             CRUN_Q_RC=1; [ "$keepgoing" = "1" ] || stopping=1 ;;
        esac
        W_PID[$s]=""; W_TASK[$s]=-1; W_SEEN[$s]=0
      fi
      s=$((s+1))
    done

    # 3. Задачи с недостижимыми зависимостями дальше не поедут никогда.
    i=0
    while [ "$i" -lt "$Q_N" ]; do
      if [ "${T_ST[$i]}" = "pending" ]; then
        crun_q_deps_state "$i"; st=$?
        if [ "$st" = "2" ]; then
          T_ST[$i]=skipped; CRUN_Q_SKIP=$((CRUN_Q_SKIP+1))
          crun_state_set "$Q_PROJ" "${T_SHA[$i]}" "${T_ID[$i]}" skipped \
            "$(jq -r ._source "${T_SPEC[$i]}")"
          warn "${T_ID[$i]}: пропущена — зависит от $(crun_q_bad_dep "$i")"
          [ "$CRUN_Q_RC" = "0" ] && CRUN_Q_RC=1
        fi
      fi
      i=$((i+1))
    done

    # 4. Запустить всё, что готово и ни с кем не спорит.
    if [ "$stopping" = "0" ]; then
      i=0
      while [ "$i" -lt "$Q_N" ]; do
        [ "${T_ST[$i]}" = "pending" ] || { i=$((i+1)); continue; }
        [ "$limit" != "0" ] && [ "$started" -ge "$limit" ] && break
        crun_q_deps_state "$i" || { i=$((i+1)); continue; }
        crun_q_conflicts "$i" && { i=$((i+1)); continue; }

        s=1; while [ "$s" -le "$Q_JOBS" ] && [ -n "${W_PID[$s]}" ]; do s=$((s+1)); done
        [ "$s" -le "$Q_JOBS" ] || break

        local work="$Q_PROJ"
        if [ "$usewt" = "1" ]; then
          work=$(crun_wt_prepare "$Q_PROJ" "$s") || {
            err "не удалось подготовить worktree слота $s"
            T_ST[$i]=failed; CRUN_Q_FAIL=$((CRUN_Q_FAIL+1)); CRUN_Q_RC=1
            i=$((i+1)); continue; }
        fi

        started=$((started+1))
        printf '%s[%d/%d] %s%s  %s\n' "$C_B" "$started" "$Q_N" "${T_ID[$i]}" "$C_RESET" \
          "$(jq -r .title "${T_SPEC[$i]}")"

        : > "$CRUN_RUNDIR/$i.res"; : > "$CRUN_RUNDIR/$i.out"
        local mwas=""
        case "$-" in *m*) mwas=1 ;; esac
        # Своя группа процессов на воркера: иначе Ctrl+C не достанет до claude,
        # запущенного внутри него (см. crun_eval_limited).
        set -m 2>/dev/null || true
        if [ "$Q_JOBS" = "1" ]; then
          crun_q_worker "$i" "$work" "$s" &
        else
          crun_q_worker "$i" "$work" "$s" > "$CRUN_RUNDIR/$i.out" 2>&1 &
        fi
        W_PID[$s]=$!
        [ -n "$mwas" ] || set +m 2>/dev/null || true

        W_TASK[$s]=$i; W_SEEN[$s]=0
        T_ST[$i]=running
        i=$((i+1))
      done
    fi

    # 5. Условия выхода: никто не бежит и запустить нечего.
    s=1; running_now=0
    while [ "$s" -le "$Q_JOBS" ]; do
      [ -n "${W_PID[$s]}" ] && running_now=$((running_now+1))
      s=$((s+1))
    done
    if [ "$running_now" = "0" ]; then
      i=0; j=0
      while [ "$i" -lt "$Q_N" ]; do
        if [ "${T_ST[$i]}" = "pending" ]; then
          if [ "$stopping" = "1" ]; then
            # Остановка на ошибке: задача не запускалась и остаётся pending
            # в state.json — следующий запуск возьмёт её как обычно.
            T_ST[$i]=notrun
            CRUN_Q_NOTRUN=$((CRUN_Q_NOTRUN+1))
          else
            # Зависимости взаимно не разрешимы — иначе задача бы стартовала.
            T_ST[$i]=blocked; CRUN_Q_BLOCK=$((CRUN_Q_BLOCK+1)); CRUN_Q_RC=2
            crun_state_set "$Q_PROJ" "${T_SHA[$i]}" "${T_ID[$i]}" blocked \
              "$(jq -r ._source "${T_SPEC[$i]}")"
            warn "${T_ID[$i]}: цикл зависимостей — задача не может стартовать"
          fi
          j=$((j+1))
        fi
        i=$((i+1))
      done
      break
    fi
    sleep 1
  done

  rm -rf "$CRUN_RUNDIR"; CRUN_RUNDIR=""
  return 0
}
