#!/bin/bash
# Weekly check of registry tag changes; reads pinned quadlet digests. Notifies
# only when a running copy is 30+ days old (OLD_DAYS below).
# Updates are explicit: python3 ~/tools/update-images.py --pull, then review
# and restart during maintenance. This check never pulls or restarts containers.
# --verbose prints every result. Local app freshness is checked by check.sh.

set -u

QUADLETS="$HOME/.config/containers/systemd"
NOTIFY="$HOME/notify.sh"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

command -v jq >/dev/null || { echo "image-check: jq is missing" >&2; exit 78; }

ARCH=$(podman info --format '{{.Host.Arch}}' 2>/dev/null)
ARCH=${ARCH:-arm64}

# ----------------------------------------------------------------- registry

# The digest the registry currently serves for a tag, without pulling a byte.
# A HEAD on the manifest returns it in a header; the Accept list has to name
# every manifest type we are willing to be told about, or the registry answers
# with a converted document and a different digest than the one podman stored.
remote_digest() { # $1=repo (e.g. library/nginx) $2=tag
  local repo=$1 tag=$2 token

  token=$(curl -fsS --connect-timeout 10 -m 20 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    2>/dev/null | jq -r '.token // empty')
  [ -n "$token" ] || return 1

  curl -fsSI --connect-timeout 10 -m 20 \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | head -1
}

# What podman holds locally for that tag. RepoDigests carries what the registry
# served at pull time, which is the same kind of digest remote_digest returns.
# .Digest is NOT usable here: depending on how an image was pulled it is
# sometimes the index digest and sometimes the per-architecture one, and
# comparing the two kinds reports a false update forever.
local_digest() { # $1=full image ref
  podman image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | sed 's/.*@//' | grep '^sha256:' | head -1
}

# The digest of the per-architecture manifest inside the index, read from the
# registry without pulling. Empty when the tag is a plain single-arch manifest.
#
# Why both this and remote_digest: what podman stores in RepoDigests is not one
# consistent kind of digest. An image pulled a while ago holds the INDEX digest;
# the same image pulled today holds the ARCH manifest digest. Comparing against
# only one of the two reports a permanent false update - grafana and pihole both
# did exactly that on 2026-09-03, minutes after being brought fully up to date.
#
# So an image counts as current when its local digest matches EITHER remote
# digest. That is not a loosening: when a tag really moves, both change, and a
# local copy matches neither. It also fixes a case worth having right - an index
# re-pushed because some other architecture was rebuilt, while the arm64 image
# is byte for byte the one already running. Nothing to pull, nothing to restart.
remote_arch_digest() { # $1=full image ref
  podman manifest inspect "$1" 2>/dev/null | jq -r --arg a "$ARCH" '
    .manifests // []
    | map(select(.platform.architecture == $a and .platform.os == "linux"))
    | .[0].digest // empty'
}

# --------------------------------------------------------------- the images

# Read from the quadlets rather than from running containers, so an image that
# is temporarily down is still checked.
STALE=""
OLD=0
# Notify only when something we run is at least this old. Every :latest tag
# moves almost weekly, so "a newer version exists" was true every Monday and the
# notification carried no information (5 of 5 on 2026-10-26). A month-old copy
# of pihole or unbound is the thing worth a nudge.
OLD_DAYS=30
CHECKED=0
UNREACHABLE=0

for f in "$QUADLETS"/*.container; do
  [ -e "$f" ] || continue

  ref=$(awk -F= '/^Image=/{print $2; exit}' "$f")
  [ -n "$ref" ] || continue

  # Locally built images (localhost/...) have no registry to ask.
  case "$ref" in docker.io/*) ;; *)
    [ "$VERBOSE" -eq 1 ] && echo "skip  $ref (not on docker.io)"
    continue ;;
  esac

  pinned_ref="$ref"
  ref=${ref%@*}
  path=${ref#docker.io/}
  tag=${path##*:}
  repo=${path%:*}
  [ "$tag" = "$path" ] && { tag=latest; repo=$path; }
  # Official images live under library/ even though nobody writes it that way.
  case "$repo" in */*) ;; *) repo="library/$repo" ;; esac

  CHECKED=$(( CHECKED + 1 ))
  have=$(local_digest "$pinned_ref")
  want=$(remote_digest "$repo" "$tag")
  want_arch=$(remote_arch_digest "$ref")

  if [ -z "$want" ]; then
    UNREACHABLE=$(( UNREACHABLE + 1 ))
    echo "image-check: could not read the registry for $ref" >&2
    continue
  fi

  if [ -z "$have" ]; then
    echo "image-check: no local copy of $ref" >&2
    continue
  fi

  if [ "$have" = "$want" ] || { [ -n "$want_arch" ] && [ "$have" = "$want_arch" ]; }; then
    [ "$VERBOSE" -eq 1 ] && echo "ok    $ref"
  else
    age=$(podman image inspect --format '{{.Created}}' "$ref" 2>/dev/null | cut -c1-10)
    days=""
    if epoch=$(date -d "$age" +%s 2>/dev/null); then
      days=$(( ( $(date +%s) - epoch ) / 86400 ))
    else
      # Unreadable date: count it as old rather than stay silent forever -
      # the trap check.sh's local-image rule fell into once.
      OLD=$(( OLD + 1 ))
    fi
    [ -n "$days" ] && [ "$days" -ge "$OLD_DAYS" ] && OLD=$(( OLD + 1 ))
    STALE="${STALE}${ref}  (local copy built ${age:-?}${days:+, $days days})
"
    [ "$VERBOSE" -eq 1 ] && echo "STALE $ref  local=${have#sha256:} index=${want#sha256:} arch=${want_arch#sha256:}"
  fi
done

# ------------------------------------------------------------------ report

if [ -z "$STALE" ]; then
  echo "image-check: $CHECKED images checked, all current${UNREACHABLE:+ ($UNREACHABLE unreachable)}"
  exit 0
fi

COUNT=$(printf '%s' "$STALE" | grep -c .)
echo "image-check: $COUNT of $CHECKED images have a newer version"
printf '%s' "$STALE"

[ -x "$NOTIFY" ] || exit 0
if [ "$OLD" -eq 0 ]; then
  echo "image-check: none older than $OLD_DAYS days - not notifying"
  exit 0
fi

# "info", not "alarm": nothing is broken and nothing needs doing tonight.
"$NOTIFY" info "Newer container images: $COUNT" \
"$(printf '%s' "$STALE")
Nothing was pulled or restarted.
When you are ready: ~/tools/update-images.py --pull; then a deliberate restart of the services" >/dev/null 2>&1 || true

exit 0
