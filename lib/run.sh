# Цикл выполнения задач. Каждая задача — отдельный процесс claude, то есть чистый контекст.

# Собрать промпт задачи из шаблона.
crun_build_prompt() {
  local proj="$1" spec="$2" tpl acc verify q prog

  tpl=$(cat "$CRUN_HOME/prompts/task-template.md")
  acc=$(jq -r '.acceptance[]? | "- " + .' "$spec")
  [ -z "$acc" ] && acc="- (в постановке не заданы — держись цели)"

  verify=$(jq -r '.verify // empty' "$spec")
  if [ -n "$verify" ]; then
    verify=$(printf '**Проверка:** после работы раннер выполнит `%s`. Убедись, что проходит.\n' "$verify")
  fi

  # Ответы владельца идут ПЕРЕД неясными местами и весомее их: это единственное,
  # что человек успел сказать до автономного прогона.
  local ans
  ans=$(jq -r '.answers[]? | "**В:** " + .q + "\n**О:** " + .a + "\n"' "$spec")
  if [ -n "$ans" ]; then
    ans=$(printf '## Решения владельца\n\nВопросы, на которые он ответил при постановке:\n\n%s\n\nЭто не пожелания, а часть задачи: следуй им, даже если сделал бы иначе.\nОтвет «на усмотрение исполнителя» означает, что выбор твой — сделай его\nосознанно и назови в summary.\n' "$ans")
  fi

  q=$(jq -r '.open_questions[]? | "- " + .' "$spec")
  if [ -n "$q" ]; then
    q=$(printf '## Неясные места\n\nПри компиляции остались вопросы:\n\n%s\n\nСпросить некого. Выбери\nразумное решение в духе проекта и опиши выбор в summary; если без ответа\nзадача теряет смысл — верни blocked.\n' "$q")
  fi
  [ -n "$ans" ] && q=$(printf '%s\n%s' "$ans" "$q")

  prog=$(crun_progress_tail "$proj")
  if [ -n "$prog" ]; then
    prog=$(printf '## Что уже сделано в проекте\n\n%s\n' "$prog")
  fi

  # Материалы задачи-папки: картинки Read показывает модели как изображения,
  # поэтому достаточно назвать пути и попросить прочитать.
  local att src srcb
  att=$(jq -r '.attachments[]? | "- `" + . + "`"' "$spec")
  if [ -n "$att" ]; then
    att=$(printf '## Материалы задачи\n\nПрежде чем начать, прочитай каждый файл инструментом Read — макеты,\nскриншоты и схемы здесь такая же часть постановки, как текст:\n\n%s\n' "$att")
  fi

  src=$(jq -r ._source "$spec")
  if [ -d "$src" ]; then
    srcb=$(printf 'Задача собрана из папки `%s` — там исходные тексты и все материалы. Если\nформулировка выше кажется неполной, загляни туда. Папка только для чтения, менять её нельзя.' "$src")
  else
    srcb=$(printf 'Задача скомпилирована из файла `%s`. Если формулировка выше кажется неполной —\nпрочитай оригинал. Файл только для чтения, менять его нельзя.' "$src")
  fi

  tpl="${tpl//\{\{TITLE\}\}/$(jq -r .title "$spec")}"
  tpl="${tpl//\{\{GOAL\}\}/$(jq -r .goal "$spec")}"
  tpl="${tpl//\{\{ACCEPTANCE\}\}/$acc}"
  tpl="${tpl//\{\{VERIFY_BLOCK\}\}/$verify}"
  tpl="${tpl//\{\{QUESTIONS_BLOCK\}\}/$q}"
  tpl="${tpl//\{\{ATTACHMENTS_BLOCK\}\}/$att}"
  tpl="${tpl//\{\{SOURCE_BLOCK\}\}/$srcb}"
  tpl="${tpl//\{\{PROGRESS_BLOCK\}\}/$prog}"
  printf '%s' "$tpl"
}

# Подсказка по установке для пропавшей verify-команды. Имя пакета по имени команды
# угадать нельзя, поэтому предлагаем то, чем в этом проекте ставятся зависимости целиком.
crun_install_hint() {
  local proj="$1" venv
  if [ -f "$proj/pyproject.toml" ]; then
    if venv=$(crun_project_venv "$proj"); then
      printf '%s/bin/python -m pip install -e ".[dev]"' "$venv"
    else
      printf 'python3 -m pip install -e ".[dev]"'
    fi
    return 0
  fi
  [ -f "$proj/requirements.txt" ] && {
    printf 'python3 -m pip install -r requirements.txt'; return 0; }
  [ -f "$proj/package.json" ] && { printf 'npm install'; return 0; }
  return 0
}

# Промпт попытки исправления — сообщение в ту же сессию, что выполняла задачу.
# Собирается через printf, а не подстановкой в шаблон: вывод проверки — произвольный
# текст, и `&`, `\` в нём ничего значить не должны. В шаблон идут только числа.
# $1 команда verify $2 номер попытки $3 сколько всего. Читает CRUN_VFAIL_SHORT и CRUN_VOUT.
crun_build_fix_prompt() {
  local verify="$1" n="$2" max="$3" vtail tpl
  # В параллельном прогоне лог задачи лежит вне worktree, и модель его не прочитает:
  # вывод идёт прямо в промпт. Хвост — там у тестов и линтеров итог.
  vtail=$(printf '%s\n' "$CRUN_VOUT" | tail -n 200 | tail -c 30000)
  [ -n "$vtail" ] || vtail="(команда ничего не вывела)"
  tpl=$(cat "$CRUN_HOME/prompts/fix.md")
  tpl="${tpl//\{\{ATTEMPT\}\}/$n}"
  tpl="${tpl//\{\{MAX\}\}/$max}"
  printf '## Проверка раннера не прошла\n\nТы отчитался, что задача сделана, но раннер выполнил свою проверку, и она не прошла.\n\n**Команда:**\n\n```\n%s\n```\n\n**Итог:** %s\n\n**Вывод команды** (последние строки):\n\n```\n%s\n```\n\n%s\n' \
    "$verify" "$CRUN_VFAIL_SHORT" "$vtail" "$tpl"
}

# Один вызов claude по задаче: первая попытка или, с $4, дозапуск той же сессии.
# Локальные переменные crun_run_one (work, bin, model, …) видны здесь по правилам
# динамической области видимости bash — отдельно их не передаём.
# $1 промпт $2 файл потока $3 файл ошибок $4 session_id для --resume (необязательно)
#
# При --resume флаги передаются все заново: --settings, MCP, --add-dir и режим прав
# из сессии не восстанавливаются, а записанный в неё системный промпт повторная
# передача того же текста не меняет.
crun_task_claude() {
  local p="$1" out="$2" errf="$3" sid="${4:-}" rc prev prevpath prevvenv pvenv
  local resume=()
  [ -n "$sid" ] && resume=(--resume "$sid")

  # Инструменты проекта в PATH — и модели, и проверке ниже. Иначе модель зовёт
  # .venv/bin/python -m pytest, а раннер потом запускает голый pytest и ловит 127.
  # Подоболочки здесь быть не может (см. ниже), поэтому PATH возвращаем руками.
  prevpath="$PATH"; prevvenv="${VIRTUAL_ENV:-}"
  if [ -n "$binpath" ]; then
    PATH="$binpath$PATH"; export PATH
    if pvenv=$(crun_project_venv "$work"); then VIRTUAL_ENV="$pvenv"; export VIRTUAL_ENV; fi
  fi

  # Раннер выполняет задачу в подоболочке-воркере, у которой своя группа процессов,
  # поэтому Ctrl+C достаёт до claude через неё, а не через CRUN_CHILD_PID.
  prev="$PWD"; cd "$work" || return 1
  crun_run_streamed "$tmo" "$out" "$errf" \
    "$bin" -p "$p" \
    ${resume[@]+"${resume[@]}"} \
    --output-format stream-json --verbose \
    --json-schema "$(cat "$CRUN_HOME/config/result-schema.json")" \
    --permission-mode dontAsk \
    --settings "$settings" \
    ${CRUN_MCP_ARGS[@]+"${CRUN_MCP_ARGS[@]}"} \
    ${srcdir[@]+"${srcdir[@]}"} \
    --append-system-prompt "$(cat "$CRUN_HOME/prompts/system.md"; printf '\n'; crun_net_prompt "$proj")" \
    --model "$model" --effort "$(crun_cfg "$proj" effort high)" \
    --max-budget-usd "$budget"
  rc=$?
  cd "$prev"
  PATH="$prevpath"; export PATH
  if [ -n "$prevvenv" ]; then VIRTUAL_ENV="$prevvenv"; export VIRTUAL_ENV; else unset VIRTUAL_ENV; fi
  return $rc
}

# Итоговое событие потока несёт отчёт, стоимость, авторитетный список отказов и id
# сессии для дозапуска. Пишет result вызывающего и CRUN_LAST_COST/TURNS/SID.
# $1 файл потока $2 куда записать отказы. 1 — отчёта нет.
crun_task_report() {
  local ev denials nden cost turns
  # Отчёт прошлой попытки не должен пережить пустой отчёт этой.
  result=""
  rm -f "$2"
  ev=$(jq -c -R 'fromjson? // empty | select(.type=="result")' "$1" 2>/dev/null | tail -1)
  [ -n "$ev" ] || return 1

  # Стоимость и шаги в событии — за этот вызов, а не за сессию: дозапуск через
  # --resume отдаёт только свои (замерено на claude 2.1.251, хотя документация
  # обещает накопительный итог). Поэтому попытки складываем.
  cost=$(printf '%s' "$ev" | jq -r '.total_cost_usd // 0')
  turns=$(printf '%s' "$ev" | jq -r '.num_turns // 0')
  CRUN_LAST_COST=$(printf '%s + %s\n' "$CRUN_LAST_COST" "$cost" | bc -l 2>/dev/null \
                   || printf '%s' "$cost")
  CRUN_LAST_TURNS=$(( CRUN_LAST_TURNS + turns ))
  CRUN_LAST_SID=$(printf '%s' "$ev" | jq -r '.session_id // empty')

  denials=$(printf '%s' "$ev" | jq -c '.permission_denials // []')
  nden=$(printf '%s' "$denials" | jq 'length')
  if [ "$nden" != "0" ]; then
    printf '%s' "$denials" | jq -r '.[] | "  ⊘ " + (.tool_name // "?") +
      (if .tool_input.command then "(" + (.tool_input.command | .[0:60]) + ")" else "" end)' \
      > "$2"
    [ "${CRUN_QUIET:-0}" != "1" ] && \
      printf '%s  отказов по правам: %s%s\n' "$C_YEL" "$nden" "$C_RESET"
  fi
  result=$(crun_claude_output "$ev")
  [ -n "$result" ]
}

# Verify — источник истины, а не самоотчёт модели.
# 0 — прошла; 1 — провалена; 2 — проверять нечем (пункт в SETUP.md уже записан).
# При провале: CRUN_VFAIL — причина целиком для LAST_FAILURE.md, CRUN_VFAIL_SHORT —
# строка на экран и для попытки исправления, CRUN_VOUT — вывод команды.
# Переменные crun_run_one видны здесь по динамической области видимости.
crun_task_verify() {
  local vblock vlive vmiss hint vtmo vfile vt0 vsecs vrc vout
  CRUN_VFAIL=""; CRUN_VFAIL_SHORT=""; CRUN_VOUT=""
  info "  проверка: $verify"

  # Команда, которая не завершается сама (`docker compose up`, dev-сервер), — это
  # проверка живучестью: успех означает «поднялось и держится», а не «вышло с 0».
  if vblock=$(crun_verify_blocking "$verify"); then vlive=1; else vlive=0; fi

  # Дальше выясняем, есть ли чем проверять. Запускать команду с отсутствующим
  # бинарём нельзя: код 127 под отрицанием (`… && ! cmd …`) превращается в 0,
  # и задача засчитывается, не будучи проверенной ни разу.
  vmiss=$(cd "$work" && crun_verify_missing "$verify" "$binpath")
  if [ -n "$vmiss" ]; then
    hint=$(crun_install_hint "$proj")
    crun_needs_write "$proj" "$id" "$(jq -n \
      --arg cmds "$vmiss" --arg id "$id" --arg v "$verify" --arg cmd "$hint" '
      [{kind: "dependency",
        what: ("установить в окружение проекта: " + $cmds),
        why:  ("раннер проверяет задачу " + $id + " командой `" + $v +
               "`, но этих команд нет в PATH проекта — проверить результат нечем"),
        command: $cmd,
        how:   ("Если инструмент ставится иначе — поставьте его в окружение проекта " +
                "(.venv, node_modules) или укажите каталог с ним в ключе toolPaths " +
                "файла .claude-runner.json.")}]')" >/dev/null
    printf '\n--- verify: %s (не запущена) ---\nнет команд в PATH: %s\n' \
      "$verify" "$vmiss" >> "$logs/$id.log"
    warn "проверка не запущена — нет команд: $vmiss"
    return 2
  fi

  # Даже завершающаяся команда может зависнуть (сеть, ожидание ввода), поэтому
  # verify всегда идёт под таймаутом — иначе висит весь прогон, а не одна задача.
  vtmo=$(crun_verify_timeout "$proj" "$spec" "$vlive")
  [ "$vlive" = "1" ] && info "  проверка живучестью ($vblock): держать ${vtmo}с"
  vfile=$(mktemp -t crun-verify)
  vt0=$(date +%s)
  crun_eval_limited "$vtmo" "$work" "$binpath" "$verify" "$vfile"; vrc=$?
  vsecs=$(( $(date +%s) - vt0 ))
  vout=$(cat "$vfile"); rm -f "$vfile"
  CRUN_VOUT="$vout"

  # Уборка обязательна и при успехе, и при провале: контейнеры живут в демоне
  # docker и снятие нашей группы процессов их не гасит.
  [ "$vlive" = "1" ] && crun_verify_teardown "$work" "$verify" "$binpath" "$logs/$id.log"

  if [ "$vlive" = "1" ]; then
    if [ "$vrc" = "124" ]; then
      # Дожила до срока — это и есть успех проверки живучестью.
      printf '\n--- verify: %s (жива %sс — успех) ---\n%s\n' "$verify" "$vtmo" "$vout" \
        >> "$logs/$id.log"
      return 0
    fi
    # Команда, которая не должна завершаться, завершилась: сборка сломалась
    # или сервис упал на старте. Код 0 здесь тоже провал — `docker compose up`
    # возвращает 0 и когда контейнер умер сам.
    printf '\n--- verify: %s (завершилась через %sс, код %s) ---\n%s\n' \
      "$verify" "$vsecs" "$vrc" "$vout" >> "$logs/$id.log"
    CRUN_VFAIL="проверка живучестью \`$verify\` не продержалась ${vtmo}с: команда завершилась через ${vsecs}с с кодом $vrc. Сервис не поднялся или упал на старте — смотрите вывод ниже."
    CRUN_VFAIL_SHORT="сервис не продержался ${vtmo}с (вышел через ${vsecs}с, код $vrc)"
    return 1
  fi

  if [ "$vrc" = "124" ]; then
    printf '\n--- verify: %s (таймаут %sс) ---\n%s\n' "$verify" "$vtmo" "$vout" >> "$logs/$id.log"
    CRUN_VFAIL="проверка \`$verify\` не уложилась в ${vtmo}с и была снята вместе с потомками. Либо команда не завершается сама, либо ей нужно больше времени — увеличьте verifyTimeout в .claude-runner.json (или verify_timeout в самой задаче)."
    CRUN_VFAIL_SHORT="проверка снята по таймауту (${vtmo}с)"
    return 1
  fi

  printf '\n--- verify: %s (exit %s) ---\n%s\n' "$verify" "$vrc" "$vout" >> "$logs/$id.log"
  if [ "$vrc" != "0" ]; then
    CRUN_VFAIL="модель отчиталась completed, но проверка \`$verify\` упала (код $vrc)"
    CRUN_VFAIL_SHORT="проверка не прошла (код $vrc)"
    return 1
  fi
  return 0
}

# Выполнить одну задачу. 0 = успех, 1 = провал, 2 = blocked.
# $1 проект $2 рабочий каталог $3 спек $4 бинарь $5 модель $6 бюджет $7 таймаут
# $8 settings $9 commit(1/0) $10 слот
# Наружу отдаёт CRUN_LAST_COST / CRUN_LAST_TURNS / CRUN_LAST_SECS / CRUN_LAST_FIXES
# для сводки.
#
# proj и work расходятся в параллельном режиме: состояние, логи и спеки всегда
# лежат у проекта (один state.json на прогон), а правит задача свой worktree.
# При jobs=1 work совпадает с proj, и поведение остаётся прежним.
#
# Упала проверка раннера — модель получает её вывод в ту же сессию и fixAttempts
# раз (по умолчанию один) пробует починить; потом проверка повторяется. Сбои самого
# claude, blocked и нехватку команд не повторяем: чинить там модели нечего.
crun_run_one() {
  local proj="$1" work="$2" spec="$3" bin="$4" model="$5" budget="$6" tmo="$7"
  local settings="$8" docommit="$9" slot="${10:-1}"
  local id sha state logs prompt rc result status summary verify needs
  local binpath t0 pypath mrc vr
  local fixmax fix=0 out den why short vfail="" errtmp

  id=$(jq -r ._id "$spec"); sha=$(jq -r ._sha "$spec")
  state=$(crun_state_dir "$proj"); logs="$state/logs"
  mkdir -p "$logs"

  CRUN_LAST_COST=0; CRUN_LAST_TURNS=0; CRUN_LAST_SECS=0
  CRUN_LAST_FIXES=0; CRUN_LAST_SID=""
  prompt=$(crun_build_prompt "$proj" "$spec")
  verify=$(jq -r '.verify // empty' "$spec")
  fixmax=$(crun_fix_attempts "$proj")
  export CRUN_GUARD_LOG="$logs/guard.log"

  # Снимок до запуска: иначе при --allow-dirty в «изменено» попадут чужие файлы,
  # которых задача не касалась.
  local before_dirty
  before_dirty=$(crun_dirty "$work" | sort)

  t0=$(date +%s)
  binpath=$(crun_project_bin_path "$work")

  # Editable-install зашивает в .venv абсолютный путь к исходникам ПРОЕКТА, а .venv
  # в worktree — симлинк на него. Без правки PYTHONPATH и модель, и verify работали
  # бы с кодом основного дерева, не видя правок задачи (подробности в parallel.sh).
  if [ "$work" != "$proj" ]; then
    pypath=$(crun_wt_pythonpath "$proj" "$work")
    if [ -n "$pypath" ]; then
      PYTHONPATH="$pypath${PYTHONPATH:+:$PYTHONPATH}"; export PYTHONPATH
    fi

    # Та же болезнь у pnpm. Перед `pnpm run` он сверяет node_modules с лок-файлом, а
    # node_modules в worktree — симлинк на основное дерево: в
    # node_modules/.pnpm-workspace-state-v1.json записан АБСОЛЮТНЫЙ путь проекта, он не
    # совпадает с worktree, и деп-статус объявляется «out of sync». Дальше умолчание
    # verifyDepsBeforeRun=install молча дёргает `pnpm install`, тот хочет пересобрать
    # modules-каталог с нуля, просит подтверждения — а stdin у verify /dev/null, и pnpm
    # падает с ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY. Задача считается провалённой,
    # хотя код в порядке.
    # Ни CI=true, ни confirmModulesPurge=false тут не подходят, хотя pnpm советует
    # именно их: они РАЗРЕШАЮТ purge, а он идёт readdir+rimraf сквозь симлинк и выносит
    # node_modules основного дерева — сразу у всех слотов.
    export pnpm_config_verify_deps_before_run=false
  fi

  crun_mcp_args "$proj"
  # В параллельном прогоне cwd — worktree, а папка задачи лежит в основном дереве,
  # вне его: без --add-dir Read отклонит её материалы по пути.
  local srcdir=()
  [ -d "$(jq -r ._source "$spec")" ] && srcdir=(--add-dir "$(jq -r ._source "$spec")")

  crun_task_claude "$prompt" "$logs/$id.jsonl" "$logs/$id.log"; rc=$?
  out="$logs/$id.jsonl"; den="$logs/$id-denials.txt"

  while :; do
    CRUN_LAST_SECS=$(( $(date +%s) - t0 ))

    why=""; short=""
    if [ "$rc" = "124" ]; then
      why="таймаут ${tmo}s — процесс снят"; short="таймаут ${tmo}s"
    elif [ "$rc" != "0" ]; then
      why="claude завершился с кодом $rc"; short="claude вышел с кодом $rc"
    elif ! crun_task_report "$out" "$den"; then
      why="не удалось разобрать отчёт задачи"; short="отчёт не разобран"
    fi
    if [ -n "$why" ]; then
      # На попытке исправления первопричина — упавшая проверка, а не сбой дозапуска.
      if [ "$fix" -gt 0 ]; then
        why="$vfail; попытка исправления $fix не удалась: $why"
        short="попытка исправления: $short"
      fi
      crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
      crun_failure_write "$proj" "$id" "$why" "$logs/$id.log" "$work" >/dev/null
      err "$short"
      return 1
    fi

    status=$(printf '%s' "$result" | jq -r '.status // "blocked"')
    summary=$(printf '%s' "$result" | jq -r '.summary // ""')

    if [ "$status" = "blocked" ]; then
      needs=$(printf '%s' "$result" | jq -c '.needs_from_user // []')
      crun_state_set "$proj" "$sha" "$id" blocked "$(jq -r ._source "$spec")"
      if [ "$(printf '%s' "$needs" | jq 'length')" != "0" ]; then
        crun_needs_write "$proj" "$id" "$needs" >/dev/null
        warn "нужно ваше участие: $summary"
        return 2
      fi
      crun_failure_write "$proj" "$id" "задача заблокирована: $(printf '%s' "$result" | jq -r '.blockers // .summary')" "$logs/$id.log" "$work" >/dev/null
      warn "заблокировано: $summary"
      return 1
    fi

    [ -n "$verify" ] || break
    crun_task_verify; vr=$?
    [ "$vr" = "0" ] && break
    if [ "$vr" = "2" ]; then
      crun_state_set "$proj" "$sha" "$id" blocked "$(jq -r ._source "$spec")"
      return 2
    fi

    vfail="$CRUN_VFAIL"
    if [ "$fix" -ge "$fixmax" ] || [ -z "$CRUN_LAST_SID" ]; then
      [ "$fix" = "1" ] && vfail="$vfail — и после попытки исправления"
      [ "$fix" -gt 1 ] && vfail="$vfail — и после $fix попыток исправления"
      crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
      crun_failure_write "$proj" "$id" "$vfail" "$logs/$id.log" "$work" >/dev/null
      err "$CRUN_VFAIL_SHORT"
      return 1
    fi

    fix=$((fix+1)); CRUN_LAST_FIXES=$fix
    warn "  $CRUN_VFAIL_SHORT — попытка исправления $fix/$fixmax"
    out="$logs/$id-fix$fix.jsonl"; den="$logs/$id-fix$fix-denials.txt"
    # crun_run_streamed обнуляет файл ошибок, а в $id.log уже лежит вывод проверки:
    # stderr попытки собираем отдельно и дописываем, чтобы LAST_FAILURE.md показал
    # всю историю задачи.
    errtmp=$(mktemp -t crun-fix)
    crun_task_claude "$(crun_build_fix_prompt "$verify" "$fix" "$fixmax")" \
      "$out" "$errtmp" "$CRUN_LAST_SID"; rc=$?
    { printf '\n--- попытка исправления %s ---\n' "$fix"; cat "$errtmp"; } >> "$logs/$id.log"
    rm -f "$errtmp"
  done

  # Обратная связь по задаче: чем модель подтвердила результат и что реально
  # изменилось на диске. Список берём из git, а не из самоотчёта модели.
  if [ "${CRUN_QUIET:-0}" != "1" ]; then
    local vsay changed nchanged shown
    vsay=$(printf '%s' "$result" | jq -r '.verification // empty' | tr '\n' ' ')
    [ -n "$vsay" ] && printf '%s  ✔ %s%s\n' "$C_DIM" \
      "$(printf '%s' "$vsay" | cut -c1-$(crun_term_width))" "$C_RESET"

    changed=$(crun_dirty "$work" | sort \
              | comm -13 <(printf '%s\n' "$before_dirty") - \
              | sed 's/^...//')
    nchanged=$(printf '%s' "$changed" | grep -c . | tr -d ' ')
    if [ "${nchanged:-0}" != "0" ]; then
      shown=$(printf '%s' "$changed" | head -4 | tr '\n' ' ')
      if [ "$nchanged" -gt 4 ]; then
        printf '%s  изменено файлов: %s — %s и ещё %s%s\n' \
          "$C_DIM" "$nchanged" "$shown" "$((nchanged-4))" "$C_RESET"
      else
        printf '%s  изменено: %s%s\n' "$C_DIM" "$shown" "$C_RESET"
      fi
    fi
  fi

  if [ "$docommit" = "1" ] && [ -d "$proj/.git" ]; then
    local subject body
    subject=$(crun_commit_subject "$spec" "$result")
    body=$(crun_commit_body "$result")
    if [ "$work" != "$proj" ]; then
      # Задача жила в своём worktree: коммитим в ветке слота и вливаем в основную.
      crun_wt_merge "$proj" "$slot" "$work" "$subject" "$body"
      mrc=$?
      if [ "$mrc" = "2" ]; then
        crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
        crun_failure_write "$proj" "$id" \
          "правки задачи не влились в основную ветку: конфликт с уже влитой задачей. Задачи правили одни и те же строки — значит, они не были независимы. Уточните depends_on или touches и запустите с --retry-failed." \
          "$logs/$id.log" "$work" >/dev/null
        err "конфликт при вливании — правки пересеклись с соседней задачей"
        return 1
      elif [ "$mrc" != "0" ]; then
        crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
        crun_failure_write "$proj" "$id" "не удалось закоммитить работу задачи" \
          "$logs/$id.log" "$work" >/dev/null
        err "не удалось закоммитить работу задачи"
        return 1
      fi
      info "  коммит: $subject"
    elif [ -n "$(crun_dirty "$proj")" ]; then
      # Ошибку коммита пишем в лог задачи, а не в /dev/null: молча несделанный
      # коммит выглядит как успешная задача и обнаруживается через день.
      # На код возврата `git add` полагаться нельзя: при игнорируемых путях внутри
      # дерева он ругается и возвращает 1, добавив при этом всё нужное. Судим по
      # тому, что реально оказалось в индексе.
      if ( cd "$proj" && git add -A -- . ':(exclude).claude-runner'
           git diff --cached --quiet && exit 1
           git commit -q -m "$subject" -m "$body" \
         ) >> "$logs/$id.log" 2>&1; then
        info "  коммит: $subject"
      else
        warn "  коммит не сделан — см. $logs/$id.log"
      fi
    fi
  fi

  crun_state_set "$proj" "$sha" "$id" done "$(jq -r ._source "$spec")"
  crun_progress_add "$proj" "$id" "$(jq -r .title "$spec")" "$summary"
  return 0
}
