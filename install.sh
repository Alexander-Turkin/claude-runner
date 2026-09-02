#!/bin/bash
# Разовая установка crun.
set -u
CRUN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$CRUN_HOME/lib/common.sh"

printf '\n%sУстановка crun%s\n\n' "$C_B" "$C_RESET"

command -v jq >/dev/null || die "нужен jq: brew install jq"
ok "jq найден"

if ! command -v claude >/dev/null 2>&1; then
  warn "claude CLI не найден в PATH"
  b=$(crun_find_claude || true)
  if [ -n "$b" ]; then
    info "  есть бинарник расширения: $b"
    info "  он привязан к версии расширения и обновится вместе с ним"
  fi
  printf '  Установить CLI глобально (npm i -g @anthropic-ai/claude-code)? [Y/n] '
  read -r a
  case "$a" in n|N) info "пропущено — будет использован бинарник расширения" ;;
    *) npm install -g @anthropic-ai/claude-code || warn "не удалось; останется бинарник расширения" ;;
  esac
else
  ok "claude CLI: $(command -v claude)"
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$CRUN_HOME/bin/crun" "$HOME/.local/bin/crun"
ok "симлинк: ~/.local/bin/crun"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "~/.local/bin уже в PATH" ;;
  *)
    if ! grep -q 'HOME/.local/bin' "$HOME/.zshrc" 2>/dev/null; then
      printf '\n# crun\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zshrc"
      ok "PATH дописан в ~/.zshrc"
    fi
    warn "откройте новый терминал или выполните: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

chmod +x "$CRUN_HOME/bin/crun" "$CRUN_HOME/hooks/guard-secrets.sh"

b=$(crun_find_claude) && ok "готово: claude $("$b" --version 2>/dev/null)" \
  || die "claude CLI так и не найден"

printf '\n%sЗапуск:%s crun\n' "$C_B" "$C_RESET"
printf '%sЕсли в headless-режиме будут проблемы с авторизацией:%s claude setup-token\n\n' \
  "$C_DIM" "$C_RESET"
