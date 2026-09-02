#!/bin/bash
# PreToolUse guard: blocks access to credential-bearing files and secret-dumping
# commands in ANY spelling, including `cat ./.env`, pipes and `bash -c "..."`.
#
# Rationale: permission rules match Bash commands by prefix, so `Bash(cat *)`
# would let `cat ./.env` through. This hook inspects the actual target instead.
#
# Input  (stdin): {"tool_name":"Bash","tool_input":{"command":"..."},...}
# Output (stdout): deny decision, or nothing (= let normal permissions decide).

set -u

INPUT=$(cat)

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')

# Only the fields that TARGET something. Deliberately not old_string/new_string:
# Claude must stay able to write "add KEY to .env" into a doc or NEEDS_INPUT.md.
targets=$(printf '%s' "$INPUT" | jq -r '
  .tool_input // {}
  | [ .file_path?, .path?, .notebook_path?, .command?, .url?, .query? ]
  | map(select(type == "string"))
  | .[]' 2>/dev/null)

[ -z "$targets" ] && exit 0

# Credential-bearing paths. Note: NOT a bare "token"/"secret" substring — that
# would block ordinary source like src/auth/token.ts and make the runner useless.
PATH_RE='(^|/|[[:space:]"'"'"'=])\.env($|\.|[[:space:]"'"'"'])'
PATH_RE="$PATH_RE"'|\.(pem|key|p12|pfx|jks|keystore)($|[[:space:]"'"'"'])'
PATH_RE="$PATH_RE"'|id_(rsa|dsa|ecdsa|ed25519)'
PATH_RE="$PATH_RE"'|/\.(ssh|aws|gnupg|docker|kube)/'
PATH_RE="$PATH_RE"'|\.(npmrc|netrc|pgpass|htpasswd)($|[[:space:]])'
PATH_RE="$PATH_RE"'|Keychains|login\.keychain'
PATH_RE="$PATH_RE"'|/\.claude(\.json)?(/|$)'
PATH_RE="$PATH_RE"'|(^|/)credentials(\.(json|ya?ml|ini|toml))?($|[[:space:]])'
PATH_RE="$PATH_RE"'|(^|/)secrets?\.(json|ya?ml|toml|env|txt)($|[[:space:]])'
PATH_RE="$PATH_RE"'|(_|\.)?(history)$|\.(bash|zsh)_history'

# Commands that dump credentials regardless of any file path.
CMD_RE='(^|[;&|(]|[[:space:]])(env|printenv|set)([[:space:]]*$|[[:space:]]*[;&|])'
CMD_RE="$CMD_RE"'|security[[:space:]]+(find|dump|export)'
CMD_RE="$CMD_RE"'|op[[:space:]]+(read|item|signin)'
CMD_RE="$CMD_RE"'|aws[[:space:]]+configure'
CMD_RE="$CMD_RE"'|gh[[:space:]]+auth[[:space:]]+token'
CMD_RE="$CMD_RE"'|defaults[[:space:]]+read'
CMD_RE="$CMD_RE"'|launchctl[[:space:]]+getenv'
CMD_RE="$CMD_RE"'|claude[[:space:]]+setup-token'

# Сеть открыта только на чтение, но GET-запрос способен унести секрет в query-строке.
# Ловим значения, похожие на ключи, в любом URL.
SECRET_VAL_RE='(sk|pk|rk)-[A-Za-z0-9_]{16,}'
SECRET_VAL_RE="$SECRET_VAL_RE"'|gh[pousr]_[A-Za-z0-9]{16,}'
SECRET_VAL_RE="$SECRET_VAL_RE"'|xox[baprs]-[A-Za-z0-9-]{10,}'
SECRET_VAL_RE="$SECRET_VAL_RE"'|AKIA[0-9A-Z]{16}'
SECRET_VAL_RE="$SECRET_VAL_RE"'|eyJ[A-Za-z0-9_-]{20,}'
SECRET_VAL_RE="$SECRET_VAL_RE"'|(api[_-]?key|token|secret|password|passwd)=[^&[:space:]]{12,}'

# Template env files carry no secrets by convention -- .env.example and friends are
# committed to the repo. Blocking them is a false positive that costs whole tasks:
# it burned T0.2 in the cardholder project and filled SETUP.md with the same request
# three times. We neutralise only the template name inside the target string, so a
# compound command like `cat .env.example && cat .env` is still blocked on the second
# half. Deliberately no "allow" decision here: this hook only stops deciding, and the
# normal permission rules still apply.
TEMPLATE_RE='s/\.env\.(example|sample|template|dist|defaults?)/.envTEMPLATE/g'

reason=""
while IFS= read -r t; do
  [ -z "$t" ] && continue
  t=$(printf '%s' "$t" | sed -E "$TEMPLATE_RE")
  if printf '%s' "$t" | grep -qE "$PATH_RE"; then
    reason="target looks like a credential-bearing file"
    break
  fi
  if [ "$tool" = "Bash" ] && printf '%s' "$t" | grep -qE "$CMD_RE"; then
    reason="command dumps credentials or environment"
    break
  fi
  if printf '%s' "$t" | grep -qEi "$SECRET_VAL_RE"; then
    reason="request carries something that looks like a credential"
    break
  fi
done <<EOF
$targets
EOF

[ -z "$reason" ] && exit 0

# Log every block so the run can be audited afterwards.
log="${CRUN_GUARD_LOG:-}"
if [ -z "$log" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  log="$CLAUDE_PROJECT_DIR/.claude-runner/logs/guard.log"
fi
if [ -n "$log" ]; then
  mkdir -p "$(dirname "$log")" 2>/dev/null
  printf '%s\tBLOCKED\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$tool" "$reason" \
    "$(printf '%s' "$targets" | tr '\n' ' ' | cut -c1-300)" >> "$log"
fi

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Blocked by crun secret guard: " + $r +
      ". Do not look for credentials on disk and do not try another spelling. " +
      "If the task genuinely needs a secret, stop and report status \"blocked\" " +
      "with needs_from_user describing what the user must add and how.")
  }
}'
exit 0
