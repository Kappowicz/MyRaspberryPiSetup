#!/bin/bash
# Push notifications via ntfy.sh, backed by an on-disk queue.
#
#   ./notify.sh alarm  "Title" "Body"   - wakes you (urgent priority)
#   ./notify.sh done   "Title" "Body"   - alarm channel, calmly (back to normal)
#   ./notify.sh info   "Title" "Body"   - quiet
#   ./notify.sh queue                   - just try to flush the backlog
#   ./notify.sh status                  - what is waiting in the queue
#   ./notify.sh test                    - sample message on both channels
#
# Every message hits the disk first and only then goes out. If sending fails
# the file STAYS and the next run tries again (timer runs every 5 minutes).
# A brief loss of internet loses nothing: once the link is back everything
# arrives, annotated with how long it waited.
#
# Exit code: 0 = queue empty (all delivered), 1 = something is still waiting.

set -u

CONF="${NOTIFY_CONF:-$HOME/.config/secrets/notify.env}"
[ -r "$CONF" ] || { echo "notify: missing $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

QUEUE="${NOTIFY_QUEUE:-$HOME/alerts/queue}"
mkdir -p "$QUEUE"

# Upper bound on the queue. A week without internet must neither fill the disk
# nor dump a thousand notifications on the phone the moment the link returns.
MAX_QUEUE=100
DROPPED_COUNTER="$QUEUE/.dropped"

RESOLVER=1.1.1.1   # fallback resolver; must not be Pi-hole - see send()

# ---------------------------------------------------------------- sending

send() { # $1=url $2=priority $3=tags $4=title $5=body
  local url=$1 prio=$2 tags=$3 title=$4 body=$5
  local host ip
  host=${url#https://}; host=${host%%/*}

  # First attempt: the ordinary way, through the host's resolv.conf (Pi-hole).
  # No --retry and a short timeout: when DNS is down every retry waits out the
  # same timeout and adds nothing. The resilience lives below.
  curl -fsS --connect-timeout 5 -m 8 \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
    -d "$body" "$url" >/dev/null 2>&1 && return 0

  # Pi-hole is both this host's resolver and the most likely thing to break in
  # the whole setup. When it dies, plain curl cannot resolve ntfy.sh, so the
  # alarm about Pi-hole being down would never leave - it would fail at exactly
  # the moment it exists for. The second attempt asks 1.1.1.1 directly
  # ("dig @" bypasses resolv.conf) and hands the address to curl.
  # Not "curl --dns-servers": this curl (8.14.1) is built without c-ares and
  # does not have that option. Verified, not assumed.
  ip=$(dig +short +time=3 +tries=1 "@$RESOLVER" "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  if [ -n "$ip" ]; then
    curl -fsS --connect-timeout 5 -m 10 --retry 2 --retry-delay 3 --resolve "$host:443:$ip" \
      -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
      -d "$body" "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ---------------------------------------------------------------- queue

enqueue() { # $1=channel(alarm|done|info) $2=title $3=body
  local channel=$1 title=$2 body=$3 file count

  # "|" separates the header fields, so it cannot appear in the title.
  title=${title//|/ }

  count=$(find "$QUEUE" -maxdepth 1 -name '*.msg' | wc -l)
  if [ "$count" -ge "$MAX_QUEUE" ]; then
    # Queue full: drop the oldest and count the loss, so that when the link
    # returns we can say exactly HOW MANY were lost. Losing them silently
    # would be worse.
    find "$QUEUE" -maxdepth 1 -name '*.msg' -print0 | sort -z | head -z -n 1 | xargs -0r rm -f
    echo $(( $(cat "$DROPPED_COUNTER" 2>/dev/null || echo 0) + 1 )) > "$DROPPED_COUNTER"
  fi

  # The name starts with a unix timestamp - 10 digits - so plain lexical
  # sorting gives chronological order.
  file="$QUEUE/$(date +%s)-$$$RANDOM.msg"
  { printf '%s|%s\n' "$channel" "$title"; printf '%s\n' "$body"; } > "$file"
}

flush_queue() {
  local file header channel title body epoch now age url prio tags dropped
  now=$(date +%s)

  for file in $(find "$QUEUE" -maxdepth 1 -name '*.msg' | sort); do
    [ -f "$file" ] || continue
    header=$(head -1 "$file")
    channel=${header%%|*}
    title=${header#*|}
    body=$(tail -n +2 "$file")

    epoch=$(basename "$file"); epoch=${epoch%%-*}
    age=$(( now - epoch ))

    case "$channel" in
      alarm) url=$NTFY_ALARM; prio=urgent;  tags=rotating_light ;;
      done)  url=$NTFY_ALARM; prio=default; tags=white_check_mark ;;
      *)     url=$NTFY_INFO;  prio=low;     tags=information_source ;;
    esac

    # A delayed message must carry ITS OWN event time, not the delivery time.
    # Otherwise you wake up to an alarm stamped 07:00 and assume the failure
    # is fresh.
    if [ "$age" -gt 120 ]; then
      body="$body

[event: $(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z'), sat in the queue for $(( age / 60 )) min - the host had no connectivity]"
    fi

    if send "$url" "$prio" "$tags" "$title" "$body"; then
      rm -f "$file"
    else
      # Stop at the first failure: order must be preserved, and with no network
      # every further attempt would only burn another timeout.
      return 1
    fi
  done

  dropped=$(cat "$DROPPED_COUNTER" 2>/dev/null || echo 0)
  if [ "$dropped" -gt 0 ] 2>/dev/null; then
    if send "$NTFY_INFO" low warning "Notification queue overflowed" \
      "During a long outage $dropped of the oldest notifications were dropped (queue limit: $MAX_QUEUE). Newer ones got through."; then
      rm -f "$DROPPED_COUNTER"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------- entry point

case "${1:-}" in
  alarm|done|info)
    [ $# -eq 3 ] || { echo "usage: $0 $1 TITLE BODY" >&2; exit 1; }
    enqueue "$1" "$2" "$3"
    flush_queue ;;
  queue)
    flush_queue ;;
  status)
    count=$(find "$QUEUE" -maxdepth 1 -name '*.msg' | wc -l)
    echo "queued: $count"
    for f in $(find "$QUEUE" -maxdepth 1 -name '*.msg' | sort); do
      e=$(basename "$f"); e=${e%%-*}
      printf '  %s  %s\n' "$(date -d "@$e" '+%Y-%m-%d %H:%M:%S')" "$(head -1 "$f")"
    done
    [ "$count" -eq 0 ] ;;
  test)
    # A channel that has never sent anything is indistinguishable from a broken
    # one. This mode exists so you can prove it deliberately, once a month.
    S=$(date "+%Y-%m-%d %H:%M:%S %Z")
    enqueue alarm "TEST of the alarm channel" "This is a test, not a failure. Host $(hostname), $S."
    enqueue info  "TEST of the info channel"  "This is a test, not a failure. Host $(hostname), $S."
    flush_queue && echo "notify: delivered" || { echo "notify: queued for later" >&2; exit 1; } ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
