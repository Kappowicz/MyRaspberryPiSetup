#!/bin/bash
# Layer 4: run ~/healthcheck.sh once a day without anyone having to watch a screen.
#
# It does not duplicate those checks and does not touch that file - it runs it
# and reads the result. Sends a notification ONLY when something is red.
# Silence means "checked and fine", not "nobody looked" - that was the whole
# lesson from the CERT blocklist that sat frozen for 53 days.
set -u
RESULT=$("$HOME/healthcheck.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
WARNINGS=$(printf '%s\n' "$RESULT" | grep -E '^\s*WARN' || true)

if [ -n "$WARNINGS" ]; then
  COUNT=$(printf '%s\n' "$WARNINGS" | wc -l)
  exec "$HOME/notify.sh" info "Daily check: $COUNT item(s) to look at" \
"$WARNINGS

Full report: ssh $(whoami)@$(hostname -I | cut -d' ' -f1) './healthcheck.sh'"
fi
exit 0
