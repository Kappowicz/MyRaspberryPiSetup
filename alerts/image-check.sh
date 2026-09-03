#!/bin/bash
# Weekly report on container images that have moved on in the registry.
#
# This deliberately does NOT update anything. `podman auto-update` pulls the
# new image and RESTARTS the container, on a daily timer with a random delay -
# an unannounced restart of Pi-hole is an unannounced DNS outage for the whole
# house, at whatever hour the randomiser picks. So podman-auto-update.timer is
# masked and this script exists in its place: it looks, it tells you, and you
# choose the moment.
#
# When you want the update, that is one command, awake, with a terminal open:
#
#   podman auto-update                 # everything labelled AutoUpdate=registry
#   podman auto-update --dry-run       # what podman itself thinks, once the
#                                      # labels are live (see below)
#
# Why this script instead of `podman auto-update --dry-run`:
# podman reads io.containers.autoupdate from the RUNNING container, and a
# container only gets the label when it is next created. These containers run
# with Restart=always and can go months without being recreated, so --dry-run
# stays silent about a genuinely stale image for exactly as long as nothing
# restarts. The label was still added to every quadlet - it is what makes the
# manual command above work - but the check below reads the quadlet files
# instead, so it is honest from the first run.
#
#   ./image-check.sh            - check, notify only if something is stale
#   ./image-check.sh --verbose  - print every image and its verdict
#
# Scope: images that come FROM a registry. The locally built localhost/city-air
# and localhost/sds011 are not here - a registry has nothing to say about them.
# alerts/check.sh watches those by build date instead and points at
# ~/rebuild-images.sh. Between the two rules every image is covered once.
#
# Exit code is 0 even when images are stale, and 0 when the registry cannot be
# reached. A stale image is news, not a fault, and a flaky link at 04:00 on a
# Sunday must not trip OnFailure= and wake anybody. Real breakage here is
# visible in the journal.

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
CHECKED=0
UNREACHABLE=0

for f in "$QUADLETS"/*.container; do
  [ -e "$f" ] || continue
  grep -q '^AutoUpdate=registry' "$f" || continue

  ref=$(awk -F= '/^Image=/{print $2; exit}' "$f")
  [ -n "$ref" ] || continue

  # Locally built images (localhost/...) have no registry to ask.
  case "$ref" in docker.io/*) ;; *)
    [ "$VERBOSE" -eq 1 ] && echo "skip  $ref (not on docker.io)"
    continue ;;
  esac

  path=${ref#docker.io/}
  tag=${path##*:}
  repo=${path%:*}
  [ "$tag" = "$path" ] && { tag=latest; repo=$path; }
  # Official images live under library/ even though nobody writes it that way.
  case "$repo" in */*) ;; *) repo="library/$repo" ;; esac

  CHECKED=$(( CHECKED + 1 ))
  have=$(local_digest "$ref")
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
    STALE="${STALE}${ref}  (local copy built ${age:-?})
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

# "info", not "alarm": nothing is broken and nothing needs doing tonight.
"$NOTIFY" info "Nowsze obrazy kontenerow: $COUNT" \
"$(printf '%s' "$STALE")
Nic nie zostalo pobrane ani zrestartowane.
Gdy bedziesz chcial: podman auto-update" >/dev/null 2>&1 || true

exit 0
