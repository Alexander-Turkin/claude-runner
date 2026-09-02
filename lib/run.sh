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

  tpl="${tpl//\{\{TITLE\}\}/$(jq -r .title "$spec")}"
  tpl="${tpl//\{\{GOAL\}\}/$(jq -r .goal "$spec")}"
  tpl="${tpl//\{\{ACCEPTANCE\}\}/$acc}"
  tpl="${tpl//\{\{VERIFY_BLOCK\}\}/$verify}"
  tpl="${tpl//\{\{QUESTIONS_BLOCK\}\}/$q}"
  tpl="${tpl//\{\{SOURCE\}\}/$(jq -r ._source "$spec")}"
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

# Выполнить одну задачу. 0 = успех, 1 = провал, 2 = blocked.
# $1 проект $2 рабочий каталог $3 спек $4 бинарь $5 модель $6 бюджет $7 таймаут
# $8 settings $9 commit(1/0) $10 слот
# Наружу отдаёт CRUN_LAST_COST / CRUN_LAST_TURNS / CRUN_LAST_SECS для сводки.
#
# proj и work расходятся в параллельном режиме: состояние, логи и спеки всегда
# лежат у проекта (один state.json на прогон), а правит задача свой worktree.
# При jobs=1 work совпадает с proj, и поведение остаётся прежним.
crun_run_one() {
  local proj="$1" work="$2" spec="$3" bin="$4" model="$5" budget="$6" tmo="$7"
  local settings="$8" docommit="$9" slot="${10:-1}"
  local id sha state logs prompt rc ev result status summary verify vout vrc needs
  local binpath prevpath prevvenv pvenv vmiss hint vblock vtmo vfile vlive vt0 vsecs
  local t0 prev denials nden pypath mrc

  id=$(jq -r ._id "$spec"); sha=$(jq -r ._sha "$spec")
  state=$(crun_state_dir "$proj"); logs="$state/logs"
  mkdir -p "$logs"

  CRUN_LAST_COST=0; CRUN_LAST_TURNS=0; CRUN_LAST_SECS=0
  prompt=$(crun_build_prompt "$proj" "$spec")
  export CRUN_GUARD_LOG="$logs/guard.log"

  # Снимок до запуска: иначе при --allow-dirty в «изменено» попадут чужие файлы,
  # которых задача не касалась.
  local before_dirty
  before_dirty=$(crun_dirty "$work" | sort)

  t0=$(date +%s)
  # Инструменты проекта в PATH — и модели, и проверке ниже. Иначе модель зовёт
  # .venv/bin/python -m pytest, а раннер потом запускает голый pytest и ловит 127.
  # Подоболочки здесь быть не может (см. ниже), поэтому PATH возвращаем руками.
  binpath=$(crun_project_bin_path "$work")
  prevpath="$PATH"; prevvenv="${VIRTUAL_ENV:-}"
  if [ -n "$binpath" ]; then
    PATH="$binpath$PATH"; export PATH
    if pvenv=$(crun_project_venv "$work"); then VIRTUAL_ENV="$pvenv"; export VIRTUAL_ENV; fi
  fi

  # Editable-install зашивает в .venv абсолютный путь к исходникам ПРОЕКТА, а .venv
  # в worktree — симлинк на него. Без правки PYTHONPATH и модель, и verify работали
  # бы с кодом основного дерева, не видя правок задачи (подробности в parallel.sh).
  if [ "$work" != "$proj" ]; then
    pypath=$(crun_wt_pythonpath "$proj" "$work")
    if [ -n "$pypath" ]; then
      PYTHONPATH="$pypath${PYTHONPATH:+:$PYTHONPATH}"; export PYTHONPATH
    fi
  fi

  # Раннер выполняет задачу в подоболочке-воркере, у которой своя группа процессов,
  # поэтому Ctrl+C достаёт до claude через неё, а не через CRUN_CHILD_PID.
  crun_mcp_args "$proj"
  prev="$PWD"; cd "$work" || return 1
  crun_run_streamed "$tmo" "$logs/$id.jsonl" "$logs/$id.log" \
    "$bin" -p "$prompt" \
    --output-format stream-json --verbose \
    --json-schema "$(cat "$CRUN_HOME/config/result-schema.json")" \
    --permission-mode dontAsk \
    --settings "$settings" \
    ${CRUN_MCP_ARGS[@]+"${CRUN_MCP_ARGS[@]}"} \
    --append-system-prompt "$(cat "$CRUN_HOME/prompts/system.md"; printf '\n'; crun_net_prompt "$proj")" \
    --model "$model" --max-budget-usd "$budget"
  rc=$?
  cd "$prev"
  PATH="$prevpath"; export PATH
  if [ -n "$prevvenv" ]; then VIRTUAL_ENV="$prevvenv"; export VIRTUAL_ENV; else unset VIRTUAL_ENV; fi
  CRUN_LAST_SECS=$(( $(date +%s) - t0 ))

  if [ "$rc" = "124" ]; then
    crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
    crun_failure_write "$proj" "$id" "таймаут ${tmo}s — процесс снят" "$logs/$id.log" "$work" >/dev/null
    err "таймаут ${tmo}s"
    return 1
  fi
  if [ "$rc" != "0" ]; then
    crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
    crun_failure_write "$proj" "$id" "claude завершился с кодом $rc" "$logs/$id.log" "$work" >/dev/null
    err "claude вышел с кодом $rc"
    return 1
  fi

  # Итоговое событие потока несёт отчёт, стоимость и авторитетный список отказов.
  ev=$(jq -c -R 'fromjson? // empty | select(.type=="result")' "$logs/$id.jsonl" 2>/dev/null | tail -1)
  if [ -n "$ev" ]; then
    CRUN_LAST_COST=$(printf '%s' "$ev" | jq -r '.total_cost_usd // 0')
    CRUN_LAST_TURNS=$(printf '%s' "$ev" | jq -r '.num_turns // 0')
    denials=$(printf '%s' "$ev" | jq -c '.permission_denials // []')
    nden=$(printf '%s' "$denials" | jq 'length')
    if [ "$nden" != "0" ]; then
      printf '%s' "$denials" | jq -r '.[] | "  ⊘ " + (.tool_name // "?") +
        (if .tool_input.command then "(" + (.tool_input.command | .[0:60]) + ")" else "" end)' \
        > "$logs/$id-denials.txt"
      [ "${CRUN_QUIET:-0}" != "1" ] && \
        printf '%s  отказов по правам: %s%s\n' "$C_YEL" "$nden" "$C_RESET"
    fi
    result=$(printf '%s' "$ev" | jq -c '.structured_output // empty')
    if [ -z "$result" ]; then
      result=$(printf '%s' "$ev" | jq -r '.result // empty' | sed '/^```/d' | jq -c . 2>/dev/null)
    fi
  fi

  if [ -z "${result:-}" ]; then
    crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
    crun_failure_write "$proj" "$id" "не удалось разобрать отчёт задачи" "$logs/$id.log" "$work" >/dev/null
    err "отчёт не разобран"
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

  # Verify — источник истины, а не самоотчёт модели.
  verify=$(jq -r '.verify // empty' "$spec")
  if [ -n "$verify" ]; then
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
      crun_state_set "$proj" "$sha" "$id" blocked "$(jq -r ._source "$spec")"
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

    # Уборка обязательна и при успехе, и при провале: контейнеры живут в демоне
    # docker и снятие нашей группы процессов их не гасит.
    [ "$vlive" = "1" ] && crun_verify_teardown "$work" "$verify" "$binpath" "$logs/$id.log"

    if [ "$vlive" = "1" ]; then
      if [ "$vrc" = "124" ]; then
        # Дожила до срока — это и есть успех проверки живучестью.
        printf '\n--- verify: %s (жива %sс — успех) ---\n%s\n' "$verify" "$vtmo" "$vout" \
          >> "$logs/$id.log"
        vrc=0
      else
        # Команда, которая не должна завершаться, завершилась: сборка сломалась
        # или сервис упал на старте. Код 0 здесь тоже провал — `docker compose up`
        # возвращает 0 и когда контейнер умер сам.
        printf '\n--- verify: %s (завершилась через %sс, код %s) ---\n%s\n' \
          "$verify" "$vsecs" "$vrc" "$vout" >> "$logs/$id.log"
        crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
        crun_failure_write "$proj" "$id" \
          "проверка живучестью \`$verify\` не продержалась ${vtmo}с: команда завершилась через ${vsecs}с с кодом $vrc. Сервис не поднялся или упал на старте — смотрите вывод ниже." \
          "$logs/$id.log" "$work" >/dev/null
        err "сервис не продержался ${vtmo}с (вышел через ${vsecs}с, код $vrc)"
        return 1
      fi
    elif [ "$vrc" = "124" ]; then
      printf '\n--- verify: %s (таймаут %sс) ---\n%s\n' "$verify" "$vtmo" "$vout" >> "$logs/$id.log"
      crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
      crun_failure_write "$proj" "$id" \
        "проверка \`$verify\` не уложилась в ${vtmo}с и была снята вместе с потомками. Либо команда не завершается сама, либо ей нужно больше времени — увеличьте verifyTimeout в .claude-runner.json (или verify_timeout в самой задаче)." \
        "$logs/$id.log" "$work" >/dev/null
      err "проверка снята по таймауту (${vtmo}с)"
      return 1
    else
      printf '\n--- verify: %s (exit %s) ---\n%s\n' "$verify" "$vrc" "$vout" >> "$logs/$id.log"
    fi
    if [ "$vrc" != "0" ]; then
      crun_state_set "$proj" "$sha" "$id" failed "$(jq -r ._source "$spec")"
      crun_failure_write "$proj" "$id" \
        "модель отчиталась completed, но проверка \`$verify\` упала (код $vrc)" "$logs/$id.log" "$work" >/dev/null
      err "проверка не прошла (код $vrc)"
      return 1
    fi
  fi

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
    if [ "$work" != "$proj" ]; then
      # Задача жила в своём worktree: коммитим в ветке слота и вливаем в основную.
      crun_wt_merge "$proj" "$slot" "$work" "$id" "$(jq -r .title "$spec")" "$summary"
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
      info "  коммит: task($id)"
    elif [ -n "$(crun_dirty "$proj")" ]; then
      # Ошибку коммита пишем в лог задачи, а не в /dev/null: молча несделанный
      # коммит выглядит как успешная задача и обнаруживается через день.
      # На код возврата `git add` полагаться нельзя: при игнорируемых путях внутри
      # дерева он ругается и возвращает 1, добавив при этом всё нужное. Судим по
      # тому, что реально оказалось в индексе.
      if ( cd "$proj" && git add -A -- . ':(exclude).claude-runner'
           git diff --cached --quiet && exit 1
           git commit -q -m "task($id): $(jq -r .title "$spec")" -m "$summary" \
         ) >> "$logs/$id.log" 2>&1; then
        info "  коммит: task($id)"
      else
        warn "  коммит не сделан — см. $logs/$id.log"
      fi
    fi
  fi

  crun_state_set "$proj" "$sha" "$id" done "$(jq -r ._source "$spec")"
  crun_progress_add "$proj" "$id" "$(jq -r .title "$spec")" "$summary"
  return 0
}
