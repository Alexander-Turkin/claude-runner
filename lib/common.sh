# Общие помощники crun. Bash 3.2 — без mapfile и ассоциативных массивов.

CRUN_HOME="${CRUN_HOME:-$HOME/claude-runner}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RESET=; C_DIM=; C_B=; C_RED=; C_GRN=; C_YEL=; C_BLU=
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Путь к CLI: PATH → $CLAUDE_BIN → бинарник VSCode-расширения (самая свежая версия).
crun_find_claude() {
  if [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then
    printf '%s' "$CLAUDE_BIN"; return 0
  fi
  local p
  p=$(command -v claude 2>/dev/null)
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  p=$(ls -d "$HOME"/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude \
       2>/dev/null | sort -V | tail -1)
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  return 1
}

crun_state_dir() { printf '%s/.claude-runner' "$1"; }

# Незакоммиченные изменения БЕЗ служебной папки раннера: она создаётся
# компиляцией ещё до проверки, и иначе дерево всегда выглядело бы грязным.
crun_dirty() {
  # -uall: иначе git схлопывает новый каталог в одну строку "docs/", и в отчёте
  # «изменено» не видно, какие файлы задача создала.
  ( cd "$1" 2>/dev/null && \
    git status --porcelain -uall -- . ':(exclude).claude-runner' 2>/dev/null )
}

# Значение из .claude-runner.json проекта, либо дефолт.
crun_cfg() {
  local proj="$1" key="$2" def="$3" f="$1/.claude-runner.json" v
  [ -f "$f" ] || { printf '%s' "$def"; return; }
  v=$(jq -r --arg k "$key" '.[$k] // empty' "$f" 2>/dev/null)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$def"
}

# Список строк из .claude-runner.json (по одной в строке). Пусто, если ключа нет.
crun_cfg_list() {
  local f="$1/.claude-runner.json"
  [ -f "$f" ] || return 0
  jq -r --arg k "$2" '(.[$k] // [])[]' "$f" 2>/dev/null
  return 0
}

# Собирает settings-файл для одного прогона:
#   allow.json + deny.json + extraAllow/extraDeny проекта
#   + динамический запрет записи в папку задач
#   + PreToolUse-хук защиты секретов
# $1 проект, $2 папка задач (абс.), $3 куда писать
crun_build_settings() {
  local proj="$1" tasks="$2" out="$3" cfg="$1/.claude-runner.json"
  local rel extra_allow='[]' extra_deny='[]'

  case "$tasks" in
    "$proj"/*) rel="${tasks#$proj/}" ;;
    *)         rel="$tasks" ;;
  esac

  local extra_dirs='[]'
  if [ -f "$cfg" ]; then
    extra_allow=$(jq -c '.extraAllow // []' "$cfg" 2>/dev/null || echo '[]')
    extra_deny=$(jq  -c '.extraDeny  // []' "$cfg" 2>/dev/null || echo '[]')
    # Доступ за пределы проекта: команда отклоняется по ПУТИ, даже если сама
    # команда разрешена (проверено: `ls /opt/homebrew/lib` при разрешённом ls).
    extra_dirs=$(jq  -c '.extraDirs  // []' "$cfg" 2>/dev/null || echo '[]')
  fi

  # Сеть на чтение. По умолчанию выключена; включается блоком "network"
  # в .claude-runner.json. Домены обязаны идти с префиксом domain: — этого
  # требует валидация правил.
  # Сеть на чтение включена по умолчанию: перечислять домены вручную неудобно.
  # Ограничить можно, задав network.domains; выключить — network.enabled: false.
  local net_on=true net_domains='[]' net_search=true net_allow='[]' deny_drop='[]'
  if [ -f "$cfg" ]; then
    net_on=$(jq -r 'if .network.enabled == false then "false" else "true" end' "$cfg" 2>/dev/null)
    net_domains=$(jq -c '.network.domains // []' "$cfg" 2>/dev/null || echo '[]')
    net_search=$(jq -r 'if .network.search == false then "false" else "true" end' "$cfg" 2>/dev/null)
  fi
  if [ "$net_on" = "true" ]; then
    net_allow=$(jq -nc --argjson d "${net_domains:-[]}" --arg se "${net_search:-true}" '
      (if ($d | length) > 0
       then ($d | map("WebFetch(domain:" + . + ")"))
       else ["WebFetch"] end)
      + (if $se == "true" then ["WebSearch"] else [] end)')
    deny_drop='["WebFetch","WebSearch"]'
  fi

  # Установка зависимостей разрешена по умолчанию; install.enabled: false
  # возвращает запрет. Правила и текст промпта должны совпадать, иначе модель
  # будет либо ломиться в запрещённое, либо не пользоваться разрешённым.
  local inst_deny='[]'
  if [ "$(crun_install_enabled "$proj")" != "true" ]; then
    inst_deny='["Bash(pip install*)","Bash(pip3 install*)","Bash(python3 -m pip install*)",
                "Bash(npm install*)","Bash(npm i *)","Bash(npm ci*)","Bash(yarn *)",
                "Bash(pnpm *)","Bash(poetry *)","Bash(uv *)","Bash(brew install*)",
                "Bash(brew reinstall*)","Bash(cargo *)","Bash(go *)"]'
  fi

  # MCP: allow-правила не принимают голый mcp__*, шаблон разрешён только после
  # literal-префикса mcp__<сервер>__. Поэтому перечисляем настроенные серверы сами.
  local mcp_allow='[]'
  if [ "$(crun_mcp_enabled "$proj")" = "true" ]; then
    mcp_allow=$(crun_mcp_servers "$proj" | jq -R -s -c 'split("\n")
      | map(select(length > 0)) | map("mcp__" + . + "__*")')
  fi

  jq -n \
    --slurpfile allow "$CRUN_HOME/config/allow.json" \
    --slurpfile deny  "$CRUN_HOME/config/deny.json" \
    --argjson xallow "$extra_allow" \
    --argjson xdeny  "$extra_deny" \
    --argjson xdirs  "$extra_dirs" \
    --argjson netallow "$net_allow" \
    --argjson mcpallow "$mcp_allow" \
    --argjson denydrop "$deny_drop" \
    --argjson instdeny "$inst_deny" \
    --arg tasksrel "$rel" \
    --arg hook "$CRUN_HOME/hooks/guard-secrets.sh" \
    '{
      permissions: {
        defaultMode: "dontAsk",
        allow: ($allow[0] + $xallow + $netallow + $mcpallow),
        deny:  (($deny[0] | map(select(. as $r | $denydrop | index($r) | not)))
                + $xdeny + $instdeny +
                ["Edit(\($tasksrel)/**)", "Write(\($tasksrel)/**)"]),
        additionalDirectories: $xdirs
      },
      hooks: {
        PreToolUse: [
          { matcher: "Bash|Read|Edit|Write|Grep|Glob|WebFetch|WebSearch",
            hooks: [ { type: "command", command: $hook } ] }
        ]
      }
    }' > "$out"
}

# Каталоги с инструментами проекта — префикс для PATH со завершающим двоеточием.
# Без него verify вида `pytest -q` падает с кодом 127, хотя pytest стоит в .venv:
# раннер запускает проверку в голом шелле, где окружение проекта не активировано.
# Переопределяется ключом toolPaths в .claude-runner.json — тогда берётся только он.
crun_project_bin_path() {
  local proj="$1" cfg="$1/.claude-runner.json" d out="" custom=""
  [ -f "$cfg" ] && custom=$(jq -r '(.toolPaths // [])[]' "$cfg" 2>/dev/null)

  if [ -n "$custom" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in /*) ;; *) d="$proj/$d" ;; esac
      [ -d "$d" ] && out="$out$d:"
    done <<EOF
$custom
EOF
    printf '%s' "$out"; return 0
  fi

  for d in .venv/bin venv/bin env/bin node_modules/.bin; do
    [ -d "$proj/$d" ] && out="$out$proj/$d:"
  done
  printf '%s' "$out"
}

# Корень venv проекта, если он есть: некоторые инструменты смотрят на VIRTUAL_ENV,
# а не только на PATH.
crun_project_venv() {
  local proj="$1" d
  for d in .venv venv env; do
    [ -x "$proj/$d/bin/python" ] && { printf '%s' "$proj/$d"; return 0; }
  done
  return 1
}

# Команды из verify, которых нет в PATH. Пустой вывод = всё на месте.
# $1 строка verify, $2 префикс PATH (см. crun_project_bin_path)
#
# Проверка нужна не только ради внятного сообщения: verify с отрицанием
# (`… && ! BOT_TOKEN= python -c "import bot.config"`) при отсутствующей команде даёт
# 127, отрицание превращает его в 0, и задача засчитывается непроверенной.
crun_verify_missing() {
  local verify="$1" prefix="${2:-}" seg w miss=""
  [ -n "$verify" ] || return 0

  # Содержимое кавычек вырезаем: иначе python -c "print(1|2)" распадётся
  # на мусорные сегменты, и мы объявим ненайденной команду, которой нет в природе.
  local stripped segs
  stripped=$(printf '%s' "$verify" | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g')
  # Разбиение делает awk, а не sed: BSD sed не понимает \n в правой части замены.
  segs=$(printf '%s\n' "$stripped" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')

  while IFS= read -r seg; do
    # Ведущие отрицание и присваивания вида VAR=value к команде не относятся.
    # Метки sed идут отдельными -e: BSD sed читает `:a; s/…` как имя метки целиком.
    seg=$(printf '%s' "$seg" | sed -E -e 's/^[[:space:]]*//' -e 's/^![[:space:]]*//' \
                                      -e ':a' \
                                      -e 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//' \
                                      -e 'ta')
    w=${seg%%[[:space:]]*}
    [ -n "$w" ] || continue

    case "$w" in
      test|'['|cd|echo|true|false|source|.|if|then|else|fi|for|while|do|done|exec|exit|set|unset|read|printf|eval|return|:) continue ;;
      *=*|'('|')'|'{'|'}') continue ;;
      # Явный путь — это файл самого проекта, а не зависимость машины. Его отсутствие
      # означает, что задача не сделала свою работу: пусть команда упадёт как обычно.
      ./*|/*|../*) continue ;;
    esac

    PATH="$prefix$PATH" command -v "$w" >/dev/null 2>&1 || miss="$miss $w"
  done <<EOF
$segs
EOF

  printf '%s' "${miss# }"
}

# Проверки, которые не завершатся сами: `docker compose up` держит контейнеры на
# переднем плане, `tail -f` и dev-серверы работают вечно. Раннер ждёт verify без
# ограничений, поэтому такая команда подвешивает весь прогон (реальный случай: T3.2
# висела 18 минут, подняв боевого бота в polling).
#
# Набор намеренно узкий: ложно забраковать рабочую проверку хуже, чем упереться
# в таймаут. Пусто и код 1 — команда считается завершающейся.
crun_verify_blocking() {
  local v; v=$(printf '%s' "$1" | tr '\n' ' ')

  if printf '%s' "$v" | grep -qE '(docker[[:space:]]+compose|docker-compose)([[:space:]]+-{1,2}[^[:space:]]+)*[[:space:]]+up'; then
    printf '%s' "$v" | grep -qE '(^|[[:space:]])(-d|--detach)([[:space:]]|$)' \
      || { printf 'docker compose up без -d'; return 0; }
  fi

  printf '%s' "$v" | grep -qE '(^|[;&|[:space:]])tail[[:space:]]+(-[a-zA-Z]*[fF])' \
    && { printf 'tail -f'; return 0; }
  printf '%s' "$v" | grep -qE '(^|[;&|[:space:]])watch[[:space:]]' \
    && { printf 'watch'; return 0; }
  printf '%s' "$v" | grep -qE '(^|[;&|[:space:]])(docker|kubectl)[[:space:]]+logs[[:space:]]+(-[a-zA-Z]*f|--follow)' \
    && { printf 'logs --follow'; return 0; }
  printf '%s' "$v" | grep -qE '(^|[;&|[:space:]])journalctl[[:space:]]+(-[a-zA-Z]*f|--follow)' \
    && { printf 'journalctl -f'; return 0; }
  printf '%s' "$v" | grep -qE '(^|[;&|[:space:]])(npm|yarn|pnpm)[[:space:]]+(run[[:space:]]+)?(start|dev|serve|watch)([[:space:]]|$)' \
    && { printf 'dev-сервер (npm/yarn start|dev|serve|watch)'; return 0; }
  printf '%s' "$v" | grep -qE 'manage\.py[[:space:]]+runserver|(^|[[:space:]])flask[[:space:]]+run|(^|[[:space:]])(uvicorn|gunicorn)[[:space:]]|python3?[[:space:]]+-m[[:space:]]+http\.server|(^|[[:space:]])rails[[:space:]]+server' \
    && { printf 'dev-сервер'; return 0; }

  return 1
}

# Сколько ждать verify: поле спека `verify_timeout` > ключ проекта > умолчание.
# У проверки живучестью срок другой по смыслу: это не запас на всякий случай,
# а сама мера — сколько сервис обязан продержаться.
# $1 проект $2 спек $3 живучесть(1/0)
crun_verify_timeout() {
  local proj="$1" spec="$2" live="$3" v
  v=$(jq -r '.verify_timeout // empty' "$spec" 2>/dev/null)
  case "$v" in
    ''|*[!0-9]*) ;;
    *) [ "$v" -gt 0 ] && { printf '%s' "$v"; return 0; } ;;
  esac
  if [ "$live" = "1" ]; then crun_cfg "$proj" livenessTimeout 30
  else                       crun_cfg "$proj" verifyTimeout 300; fi
}

# Прибрать за проверкой живучестью. Группу процессов снимает crun_eval_limited,
# но контейнеры живут в демоне docker, а не под нами: снятие `docker compose up`
# их не гасит, и после прогона на машине остаётся работающий сервис.
# $1 проект $2 команда verify $3 префикс PATH $4 файл лога задачи
crun_verify_teardown() {
  local proj="$1" verify="$2" prefix="$3" log="$4" out rc
  printf '%s' "$verify" \
    | grep -qE '(docker[[:space:]]+compose|docker-compose)([[:space:]]+-{1,2}[^[:space:]]+)*[[:space:]]+up' \
    || return 0
  out=$(mktemp -t crun-teardown)
  crun_eval_limited 90 "$proj" "$prefix" 'docker compose down --remove-orphans' "$out"; rc=$?
  printf '\n--- уборка: docker compose down (exit %s) ---\n%s\n' "$rc" "$(cat "$out")" >> "$log"
  rm -f "$out"
  return 0
}

# ---------- взаимное исключение ----------
# Параллельные воркеры пишут в один state.json и в одно основное дерево git.
# flock на macOS нет, поэтому лок — это каталог: mkdir атомарен на любой ФС.
#
# В лок кладётся pid раннера. В подоболочке bash 3.2 $$ — это pid родителя
# (BASHPID появился только в 4.0), и здесь это ровно то, что нужно: воркеры
# живут не дольше раннера, поэтому «жив ли владелец лока» = «жив ли раннер».
# $1 путь лока, $2 таймаут секунд (по умолчанию 120)
crun_lock() {
  local d="$1" limit="${2:-120}" waited=0 owner
  mkdir -p "$(dirname "$d")"
  while ! mkdir "$d" 2>/dev/null; do
    # Лок от раннера, убитого kill -9, иначе завесил бы прогон навсегда.
    owner=$(cat "$d/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$d"; continue
    fi
    if [ "$waited" -ge "$limit" ]; then return 1; fi
    sleep 1; waited=$((waited+1))
  done
  printf '%s' "$$" > "$d/pid" 2>/dev/null
  return 0
}

crun_unlock() { rm -rf "$1" 2>/dev/null; return 0; }

crun_lock_dir() { printf '%s/locks/%s.lock' "$(crun_state_dir "$1")" "$2"; }

# Выполнить команду с ограничением по времени, забрав с собой всех потомков.
# 124 = не уложилась. $1 секунды $2 каталог $3 префикс PATH $4 команда $5 файл вывода
#
# `set -m` перед запуском обязателен: без job control фоновая подоболочка остаётся
# в группе процессов раннера, и снять её потомков (docker, сервер) было бы нечем —
# по таймауту умер бы только сам шелл, а процессы остались бы сиротами.
crun_eval_limited() {
  local limit="$1" dir="$2" prefix="$3" cmd="$4" out="$5"
  local pid waited=0 rc g mwas=""
  : > "$out"

  case "$-" in *m*) mwas=1 ;; esac
  set -m 2>/dev/null || true
  # stdin из /dev/null: иначе команда вычитает поток очереди задач (см. crun_run_limited).
  ( cd "$dir" && export PATH="$prefix$PATH" && eval "$cmd" ) > "$out" 2>&1 < /dev/null &
  pid=$!
  [ -n "$mwas" ] || set +m 2>/dev/null || true

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      # На время снятия глушим stderr: bash сообщает о прибитой работе строкой
      # вида "line 3: 12345 Terminated", которая в отчёте выглядит как сбой раннера.
      exec 3>&2 2>/dev/null
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      g=0
      while kill -0 "$pid" 2>/dev/null && [ "$g" -lt 5 ]; do sleep 1; g=$((g+1)); done
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      exec 2>&3 3>&-
      return 124
    fi
    sleep 1; waited=$((waited+1))
  done

  wait "$pid"; rc=$?
  return $rc
}

# Запуск claude с ограничением по времени. Системного timeout на macOS нет.
# $1 секунды, далее команда. Код возврата 124 = таймаут.
crun_run_limited() {
  local limit="$1"; shift
  # stdin обязательно из /dev/null: иначе дочерний claude вычитывает поток,
  # из которого читает вызывающий while-цикл, и очередь обрывается после
  # первой же задачи.
  "$@" < /dev/null &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$limit" ] && {
      kill -TERM "$pid" 2>/dev/null
      local g=0
      while kill -0 "$pid" 2>/dev/null && [ "$g" -lt 5 ]; do sleep 1; g=$((g+1)); done
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    }
    sleep 1; waited=$((waited+1))
  done
  wait "$pid"
}

# Ширина для обрезки строк прогресса.
crun_term_width() {
  local w
  w=$(tput cols 2>/dev/null)
  [ -z "$w" ] && w=100
  w=$(( w - 16 ))
  [ "$w" -lt 30 ] && w=30
  printf '%s' "$w"
}

# NDJSON из потока событий → строки экрана. При --quiet просто поглощает ввод.
crun_stream_render() {
  if [ "${CRUN_QUIET:-0}" = "1" ]; then cat > /dev/null; return 0; fi
  jq -R -r \
     --arg dim "$C_DIM" --arg reset "$C_RESET" --arg grn "$C_GRN" \
     --arg blu "$C_BLU" --arg yel "$C_YEL" \
     --argjson w "$(crun_term_width)" \
     -f "$CRUN_HOME/lib/stream.jq" 2>/dev/null
}

# Как crun_run_limited, но по ходу дела сливает новые строки вывода на экран.
# Конвейера здесь нет намеренно: в `cmd | render` переменная $! указывала бы на
# render, и снятие зависшего процесса перестало бы доставать до самого claude.
# $1 лимит секунд, $2 файл вывода, $3 файл ошибок, далее команда. 124 = таймаут.
crun_run_streamed() {
  local limit="$1" out="$2" errf="$3"; shift 3
  : > "$out"; : > "$errf"
  "$@" > "$out" 2> "$errf" &
  local pid=$! seen=0 waited=0 quiet_for=0 total rc g steps

  CRUN_CHILD_PID=$pid
  while kill -0 "$pid" 2>/dev/null; do
    total=$(wc -l < "$out" 2>/dev/null | tr -d " ")
    [ -z "$total" ] && total=0
    if [ "$total" -gt "$seen" ]; then
      sed -n "$((seen+1)),${total}p" "$out" | crun_stream_render
      seen=$total; quiet_for=0
    else
      quiet_for=$((quiet_for+1))
      # Долгий шаг (большая правка, тесты) — показать, что процесс жив.
      if [ "$quiet_for" -ge 20 ] && [ "${CRUN_QUIET:-0}" != "1" ]; then
        steps=$(grep -c '"type":"tool_use"' "$out" 2>/dev/null | tr -d " ")
        printf '%s  ⋯ ещё работаю (%d:%02d · шагов %s)%s\n' \
          "$C_DIM" $((waited/60)) $((waited%60)) "${steps:-0}" "$C_RESET"
        quiet_for=0
      fi
    fi

    if [ "$waited" -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null
      g=0
      while kill -0 "$pid" 2>/dev/null && [ "$g" -lt 5 ]; do sleep 1; g=$((g+1)); done
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      CRUN_CHILD_PID=""
      return 124
    fi
    sleep 1; waited=$((waited+1))
  done

  wait "$pid"; rc=$?
  CRUN_CHILD_PID=""
  total=$(wc -l < "$out" 2>/dev/null | tr -d " ")
  [ -z "$total" ] && total=0
  [ "$total" -gt "$seen" ] && sed -n "$((seen+1)),${total}p" "$out" | crun_stream_render
  return $rc
}

# Время в м:сс.
crun_fmt_time() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Память о прошлом запуске. Глобально хранится последний проект,
# в самом проекте — папка задач и флаги прогона: у разных проектов они разные.
CRUN_LAST_GLOBAL="$CRUN_HOME/last.json"

crun_last_project() {
  [ -f "$CRUN_LAST_GLOBAL" ] || return 1
  local p; p=$(jq -r '.project // empty' "$CRUN_LAST_GLOBAL" 2>/dev/null)
  [ -n "$p" ] && [ -d "$p" ] || return 1
  printf '%s' "$p"
}

crun_last_file() { printf '%s/last.json' "$(crun_state_dir "$1")"; }

# $1 проект, $2 ключ, $3 значение по умолчанию
crun_last_get() {
  local f v; f=$(crun_last_file "$1")
  [ -f "$f" ] || { printf '%s' "$3"; return; }
  v=$(jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$3"
}

# Запомненная модель ($2 = model | planModel). Верим только записям с маркером
# modelsExplicit: раньше сохранялся и дефолт, и старый "sonnet" залипал бы навсегда.
crun_last_model() {
  local f; f=$(crun_last_file "$1")
  [ -f "$f" ] || return 0
  [ "$(jq -r '.modelsExplicit // empty' "$f" 2>/dev/null)" = "1" ] || return 0
  crun_last_get "$1" "$2" ""
}

# $3 и $8 — только явно заданные флагами модели, иначе пусто.
# $1 проект $2 папка задач $3 модель $4 no-commit $5 continue-on-error
# $6 allow-dirty $7 limit $8 plan-model $9 jobs
crun_last_save() {
  local f; f=$(crun_last_file "$1")
  mkdir -p "$(dirname "$f")"
  jq -n --arg t "$2" --arg m "$3" --arg nc "$4" --arg ce "$5" \
        --arg ad "$6" --arg lim "$7" --arg pm "$8" --arg j "${9:-}" \
        --arg at "$(date '+%Y-%m-%d %H:%M')" \
    '{tasks:$t, model:$m, planModel:$pm, modelsExplicit:"1", noCommit:$nc, continueOnError:$ce,
      allowDirty:$ad, limit:$lim, jobs:$j, at:$at}' > "$f"
  jq -n --arg p "$1" --arg at "$(date '+%Y-%m-%d %H:%M')" \
    '{project:$p, at:$at}' > "$CRUN_LAST_GLOBAL"
}

# Человекочитаемое описание прошлого запуска.
crun_last_summary() {
  local proj="$1" t m nc ce ad j extra=""
  t=$(crun_last_get "$proj" tasks "")
  [ -n "$t" ] || return 1
  m=$(crun_last_model "$proj" model)
  [ -n "$m" ] || m=$(crun_cfg "$proj" model opus)
  nc=$(crun_last_get "$proj" noCommit 0)
  ce=$(crun_last_get "$proj" continueOnError 0)
  ad=$(crun_last_get "$proj" allowDirty 0)
  j=$(crun_last_get "$proj" jobs "")
  [ -n "$j" ] && [ "$j" != "1" ] && extra="$extra · в $j потока"
  [ "$nc" = "1" ] && extra="$extra · без коммитов"
  [ "$ce" = "1" ] && extra="$extra · не вставать на ошибке"
  [ "$ad" = "1" ] && extra="$extra · грязное дерево ок"
  printf '%s · %s%s' "$(basename "$t")/" "$m" "$extra"
}

crun_mcp_enabled() {
  local cfg="$1/.claude-runner.json"
  [ -f "$cfg" ] || { printf 'true'; return; }
  jq -r 'if .mcp == false then "false" else "true" end' "$cfg" 2>/dev/null || printf 'true'
}

# Настроенные MCP-серверы: пользовательский конфиг, конфиг проекта и .mcp.json.
# Имена нормализуются так же, как их нормализует сам CLI.
crun_mcp_servers() {
  local proj="$1"
  { jq -r '.mcpServers // {} | keys[]?' "$HOME/.claude.json" 2>/dev/null
    jq -r --arg p "$proj" '.projects[$p].mcpServers // {} | keys[]?' "$HOME/.claude.json" 2>/dev/null
    [ -f "$proj/.mcp.json" ] && jq -r '.mcpServers // {} | keys[]?' "$proj/.mcp.json" 2>/dev/null
  } | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g' | grep -v '^$' | sort -u
}

# Флаги MCP для запуска. Три режима:
#   mcp: false          → --strict-mcp-config без конфигов = все серверы отрезаны
#   задан mcpConfig     → --strict-mcp-config + этот файл = только он
#   по умолчанию        → без флага = доступны серверы, настроенные у пользователя
# Заполняет массив CRUN_MCP_ARGS.
crun_mcp_args() {
  local proj="$1" cfg="$1/.claude-runner.json" path
  CRUN_MCP_ARGS=()

  if [ "$(crun_mcp_enabled "$proj")" != "true" ]; then
    CRUN_MCP_ARGS=(--strict-mcp-config)
    return 0
  fi

  [ -f "$cfg" ] || return 0
  path=$(jq -r '.mcpConfig // empty' "$cfg" 2>/dev/null)
  [ -n "$path" ] || return 0
  case "$path" in /*) ;; *) path="$proj/$path" ;; esac
  if [ ! -f "$path" ]; then
    warn "mcpConfig указывает на несуществующий файл: $path"
    return 0
  fi
  CRUN_MCP_ARGS=(--strict-mcp-config --mcp-config "$path")
}

crun_install_enabled() {
  local cfg="$1/.claude-runner.json"
  [ -f "$cfg" ] || { printf 'true'; return; }
  # В jq `false // true` даёт true — оператор // ловит и null, и false.
  jq -r 'if .install.enabled == false then "false" else "true" end' "$cfg" 2>/dev/null \
    || printf 'true'
}

# Раздел промпта про установку зависимостей.
crun_install_prompt() {
  printf '\n## Зависимости\n\n'
  if [ "$(crun_install_enabled "$1")" != "true" ]; then
    printf 'Ставить пакеты нельзя. Не хватает зависимости — останавливайся и оформляй\n'
    printf 'её через needs_from_user с точной командой установки в поле command.\n'
    return
  fi
  printf 'Ставить зависимости можно: pip, npm, brew, uv, poetry, cargo, go.\n\n'
  printf 'Правила:\n'
  printf -- '- ставь только то, что нужно текущей задаче, и не обновляй чужие версии заодно;\n'
  printf -- '- для Python предпочитай окружение проекта (`.venv`), а не системный интерпретатор;\n'
  printf -- '- глобальные установки (`npm i -g`, `pip install --user`) запрещены — ставь в проект;\n'
  printf -- '- фиксируй добавленное в манифесте (`pyproject.toml`, `package.json`), а не только\n'
  printf '  в окружении: иначе следующая задача начнётся со сломанной сборки;\n'
  printf -- '- публикация пакетов (`npm publish`, `twine upload`) и удаление системных пакетов\n'
  printf '  (`brew uninstall`) запрещены.\n\n'
  printf 'Установка тянет и выполняет чужой код, поэтому не ставь пакет, которого нет в\n'
  printf 'постановке и который ты не можешь обосновать. Сомневаешься в имени пакета —\n'
  printf 'сверься с pypi/npm через WebFetch, а не угадывай: опечатка в имени — это чужой пакет.\n'
}

# Раздел системного промпта про сеть. Промпт обязан отражать фактические права:
# иначе модель либо не пользуется разрешённой сетью, либо ломится в запрещённую.
crun_net_prompt() {
  local cfg="$1/.claude-runner.json" on=true doms="" search=true mcp
  if [ -f "$cfg" ]; then
    on=$(jq -r 'if .network.enabled == false then "false" else "true" end' "$cfg" 2>/dev/null)
    doms=$(jq -r '(.network.domains // []) | join(", ")' "$cfg" 2>/dev/null)
    search=$(jq -r 'if .network.search == false then "false" else "true" end' "$cfg" 2>/dev/null)
  fi
  mcp=$(crun_mcp_enabled "$1")

  printf '## Сеть\n\n'
  if [ "$on" != "true" ]; then
    printf 'Сети нет. Любой сетевой вызов будет отклонён — не пробуй.\n'
    printf 'Нужны данные извне — останавливайся с needs_from_user.\n'
    return
  fi

  printf 'Сеть доступна **только на чтение** через инструмент WebFetch'
  [ "$search" = "true" ] && printf ' и WebSearch'
  printf '.\n\n'
  if [ -n "$doms" ]; then
    printf 'Разрешённые домены: %s.\n' "$doms"
    printf 'Другие домены отклоняются. Нужен домен вне списка — не подбирай обходной\n'
    printf 'путь, а верни needs_from_user с просьбой добавить его в network.domains.\n\n'
  else
    printf 'Ограничений по доменам нет.\n\n'
  fi
  printf 'Пользуйся этим, когда нужны актуальные данные о библиотеках: версии, сигнатуры\n'
  printf 'API, миграционные заметки. Твои знания могли устареть — если пишешь код против\n'
  printf 'внешней библиотеки и не уверен в текущем API, сверься с документацией.\n\n'
  printf '`curl` и `wget` по-прежнему запрещены: качай через WebFetch. Никогда не передавай\n'
  printf 'в запросе содержимое файлов проекта, ключи и токены — ни в пути, ни в query-строке.\n'

  crun_install_prompt "$1"

  if [ "$mcp" = "true" ]; then
    printf '\n## MCP\n\nПодключённые MCP-серверы доступны. Если среди них есть сервер с\n'
    printf 'документацией или данными по библиотекам — предпочитай его: он точнее, чем\n'
    printf 'скачивание страниц. Инструментов нет — значит серверы не настроены, это не сбой.\n'
  fi
}

# Заголовок коммита задачи: type(scope): subject (ticket).
# type/scope/subject даёт исполнитель в отчёте — он знает, что сделал; ticket —
# номер внешнего трекера из спека. Внутренний id раннера сюда не попадает.
# $1 файл спека $2 JSON отчёта исполнителя
# Тело коммита: английское commit.body из отчёта, а без него — summary.
crun_commit_body() {
  local r="${1:-}"
  printf '%s' "$r" | jq -e 'type == "object"' >/dev/null 2>&1 || r='{}'
  printf '%s' "$r" | jq -r '
    [.commit.body, .summary] | map(select(type == "string" and . != "")) | first // ""'
}

crun_commit_subject() {
  local r="${2:-}"
  # Отчёт может прийти битым или пустым — коммит из-за этого терять нельзя.
  printf '%s' "$r" | jq -e 'type == "object"' >/dev/null 2>&1 || r='{}'
  jq -r --argjson r "$r" '
    def nz: select(type == "string" and . != "");
    . as $s | ($r.commit // {}) as $c
    | ([$c.type | nz] | first // "feat") as $ty
    | ([$c.scope | nz] | first) as $sc
    | ([$c.subject | nz] | first // $s.title) as $su
    | ([$s.ticket | nz] | first) as $tk
    | $ty + (if $sc then "(" + $sc + ")" else "" end) + ": " + $su
      + (if $tk then " (" + $tk + ")" else "" end)' "$1"
}

# SHA содержимого — ключ кэша компиляции. У задачи-папки хэшируется список
# «путь + хэш» всех её файлов: добавленная или изменённая картинка тоже требует
# перекомпиляции, как правка текста.
crun_sha() {
  if [ -d "$1" ]; then
    (cd "$1" && find . -type f ! -path '*/.*' | LC_ALL=C sort \
       | while IFS= read -r f; do
           printf '%s %s\n' "$f" "$(shasum -a 256 "$f" | cut -c1-64)"
         done) | shasum -a 256 | cut -c1-12
    return
  fi
  shasum -a 256 "$1" 2>/dev/null | cut -c1-12
}

crun_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9а-яё]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-40
}
