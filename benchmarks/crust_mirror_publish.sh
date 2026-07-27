#!/usr/bin/env bash
# crust_mirror_publish.sh — publish ONE CRUST-bench project's SAFE (uplift) Rust
# crate as a PUBLIC, LICENSED mirror repo and wire it as a git SUBMODULE of the
# SHOWCASE repo (mirrors/<project>-rust/). See TWO_MODE_CONTRACT.md §8.
#
#     crust_mirror_publish.sh --project <name> --safe-out <crate_dir> \
#         --cbench <CBench/project> --version <ver> [--publish]
#
# Without --publish (DEFAULT = DRY-RUN): build the mirror working tree + license
# locally in a staging dir and print what WOULD happen — NO `gh repo create`, NO
# push, NO submodule add. WITH --publish: create-if-missing the public repo,
# push the SAFE crate, then add/update the showcase submodule pointer (staged,
# NOT committed — run_all.sh bundles the showcase commit, contract §9.7).
#
# SAFETY (mirrors bench/sync-mirrors.sh):
#   * ORIGIN-GUARDED: only ever pushes to / touches a repo whose `origin` really
#     is `*-rust-mirror` — never the showcase or transpiler repo.
#   * NON-EMPTY-GUARDED: refuses to publish an empty safe-out (never --delete a
#     mirror to empty).
#   * DIFF-GATED: commits/pushes only on real content change.
#   * DIR-LOCKED (per project), NON-FATAL, OFFLINE-SAFE.
#   * NEVER fabricates a license — falls back to NOTICE.md linking upstream.
set -uo pipefail

warn() { echo "[crust-mirror] $*" >&2; }
die()  { warn "$*"; exit 0; }   # non-fatal: skip, never break run_all.sh

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
PROJECT=""; SAFE_OUT=""; CBENCH=""; VERSION=""; PUBLISH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)  PROJECT="${2:?}"; shift 2 ;;
    --safe-out) SAFE_OUT="${2:?}"; shift 2 ;;
    --cbench)   CBENCH="${2:?}"; shift 2 ;;
    --version)  VERSION="${2:?}"; shift 2 ;;
    --publish)  PUBLISH=1; shift ;;
    *) warn "unknown arg: $1"; shift ;;
  esac
done
[ -n "$PROJECT" ]  || die "usage: --project <name> --safe-out <dir> --cbench <dir> --version <ver> [--publish]"
[ -n "$SAFE_OUT" ] || die "$PROJECT: --safe-out is required."
[ -n "$CBENCH" ]   || die "$PROJECT: --cbench is required."
VERSION="${VERSION:-unknown}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWCASE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # script lives in showcase/benchmarks/

REPO_NAME="o2alexanderfedin/${PROJECT}-rust-mirror"
MIRROR_URL="https://github.com/${REPO_NAME}.git"
SM_PATH="mirrors/${PROJECT}-rust"               # submodule path inside the showcase repo

# All scratch lives under the project's own ./temp/ (never /tmp), and is
# trap-cleaned on exit. run_all.sh may override via MIRROR_TEMP so every stage
# shares one temp root that run_all removes at the end.
TEMP_ROOT="${MIRROR_TEMP:-$SHOWCASE_ROOT/temp}"
mkdir -p "$TEMP_ROOT"

# ---------------------------------------------------------------------------
# NON-EMPTY guard: the SAFE crate must actually exist and be non-empty.
# ---------------------------------------------------------------------------
if [ ! -d "$SAFE_OUT" ] || [ -z "$(find "$SAFE_OUT" -type f -not -path '*/.git/*' -not -path '*/target/*' 2>/dev/null | head -1)" ]; then
  die "$PROJECT: safe-out '$SAFE_OUT' is empty/missing — refusing to publish an empty mirror."
fi

# ---------------------------------------------------------------------------
# Resolve upstream url + commit from the CBench checkout.
# ---------------------------------------------------------------------------
UP_URL="$(git -C "$CBENCH" config --get remote.origin.url 2>/dev/null || echo '')"
UP_COMMIT="$(git -C "$CBENCH" rev-parse HEAD 2>/dev/null || echo 'unknown')"
[ -n "$UP_URL" ] || UP_URL="(unknown upstream — no origin in ${CBENCH}/.git/config)"

# ---------------------------------------------------------------------------
# Detect upstream root license (case-insensitive LICENSE*/COPYING*/LICENCE*).
# ---------------------------------------------------------------------------
LICENSE_SRC=""
if [ -d "$CBENCH" ]; then
  LICENSE_SRC="$(find "$CBENCH" -maxdepth 1 -type f \
      \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'LICENCE*' \) 2>/dev/null | sort | head -1)"
fi
if [ -n "$LICENSE_SRC" ]; then LICENSE_NAME="$(basename "$LICENSE_SRC")"; else LICENSE_NAME="NONE-FOUND"; fi

# ---------------------------------------------------------------------------
# Build the mirror working tree in a staging dir.
# ---------------------------------------------------------------------------
STAGING="$(mktemp -d "$TEMP_ROOT/crust-mirror-${PROJECT}.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

# 1) SAFE crate (contract excludes) — a fresh crate, never carrying stray metadata.
rsync -a --delete --exclude '.git' --exclude 'README.md' --exclude '.gitignore' \
      --exclude 'target/' "$SAFE_OUT"/ "$STAGING"/

# 2) License propagation (copy real file) OR honest NOTICE.md — NEVER fabricate.
if [ -n "$LICENSE_SRC" ]; then
  cp "$LICENSE_SRC" "$STAGING/$LICENSE_NAME"
else
  cat >"$STAGING/NOTICE.md" <<EOF
# NOTICE

No upstream root license file (LICENSE / COPYING / LICENCE) was found in the
upstream source at the time this mirror was generated.

Upstream: ${UP_URL}
Commit:   ${UP_COMMIT}

This mirror contains machine-generated Rust transpiled from the upstream C
sources. Consult the upstream repository above for its licensing terms; no
license is asserted or fabricated here.
EOF
fi

# 3) Generated README.md (contract §8 wording).
cat >"$STAGING/README.md" <<EOF
# ${PROJECT}-rust-mirror

Generated artifact — do NOT hand-edit. Safe (uplift) Rust transpiled from
${UP_URL} @ ${UP_COMMIT} by clang2rust ${VERSION}. Upstream license: ${LICENSE_NAME}.
EOF

FILE_COUNT="$(find "$STAGING" -type f | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# DRY-RUN (default): report what WOULD happen; touch nothing remote/local.
# ---------------------------------------------------------------------------
if [ "$PUBLISH" -ne 1 ]; then
  cat <<EOF
[crust-mirror] DRY-RUN (${PROJECT}) — no repo created, nothing pushed, no submodule added.
  would-create-repo : ${REPO_NAME} (public)
  submodule-path    : ${SM_PATH}/   (in showcase repo ${SHOWCASE_ROOT})
  upstream          : ${UP_URL} @ ${UP_COMMIT}
  license           : ${LICENSE_NAME}$( [ -z "$LICENSE_SRC" ] && printf ' (NOTICE.md fallback written)' )
  staged-files      : ${FILE_COUNT}
  clang2rust ver    : ${VERSION}
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# PUBLISH: per-project dir-lock so concurrent run_all.sh jobs never collide.
# ---------------------------------------------------------------------------
LOCK="$TEMP_ROOT/crust-mirror-${PROJECT}.lock"
if ! mkdir "$LOCK" 2>/dev/null; then die "$PROJECT: another publish in progress — skip."; fi
trap 'rm -rf "$STAGING"; rmdir "$LOCK" 2>/dev/null || true' EXIT

command -v gh >/dev/null 2>&1 || die "$PROJECT: gh CLI not found — cannot publish; skip."

# 1) Create-if-missing (idempotent).
if gh repo view "$REPO_NAME" >/dev/null 2>&1; then
  warn "$PROJECT: repo $REPO_NAME already exists — reusing."
else
  if ! gh repo create "$REPO_NAME" --public \
       --description "clang2rust safe-uplift Rust mirror of ${UP_URL}" >/dev/null 2>&1; then
    die "$PROJECT: gh repo create $REPO_NAME failed (offline / no creds) — skip."
  fi
  warn "$PROJECT: created $REPO_NAME."
fi

# 2) Clone-or-init the mirror working tree.
WORK="$(mktemp -d "$TEMP_ROOT/crust-mirror-work-${PROJECT}.XXXXXX")"
trap 'rm -rf "$STAGING" "$WORK"; rmdir "$LOCK" 2>/dev/null || true' EXIT
if git clone -q "$MIRROR_URL" "$WORK" 2>/dev/null && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
  :
else
  rm -rf "$WORK"; mkdir -p "$WORK"
  git -C "$WORK" init -q
  git -C "$WORK" remote add origin "$MIRROR_URL"
fi

# ORIGIN guard: refuse to touch anything whose origin is not a *-rust-mirror.
ORIGIN="$(git -C "$WORK" remote get-url origin 2>/dev/null || echo '')"
case "$ORIGIN" in
  *-rust-mirror*) ;;  # good
  *) die "$PROJECT: mirror origin is '$ORIGIN' (not *-rust-mirror) — REFUSING to touch it." ;;
esac

# 3) Refresh content from staging (preserve the mirror's .git).
rsync -a --delete --exclude '.git' --exclude 'target/' "$STAGING"/ "$WORK"/

# 4) Commit (diff-gated) + push.
PUSHED_OK=0
( cd "$WORK"
  [ -z "$(git status --porcelain)" ] && { echo "[crust-mirror] $PROJECT: mirror unchanged."; exit 3; }
  git add -A
  git -c user.name='Alex Fedin' -c user.email='alex_fedin@hotmail.com' \
      commit -q -m "Publish ${PROJECT} safe-uplift Rust mirror @ clang2rust ${VERSION}" || exit 1
  if git push -q origin HEAD:main 2>/dev/null; then
    echo "[crust-mirror] $PROJECT: pushed $(git rev-parse --short HEAD)."; exit 0
  fi
  warn "$PROJECT: push failed (offline / no creds) — committed locally."; exit 1 )
rc=$?
# rc 0 = pushed; 3 = unchanged (still wire the submodule); 1 = commit/push problem.
[ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] && PUSHED_OK=1
[ "$PUSHED_OK" -eq 1 ] || die "$PROJECT: mirror not pushed — skipping submodule wiring."

# ---------------------------------------------------------------------------
# 5) Wire the mirror as a SUBMODULE of the showcase repo (stage pointer only;
#    the showcase commit is bundled by run_all.sh, contract §9.7).
# ---------------------------------------------------------------------------
[ -e "$SHOWCASE_ROOT/.git" ] || die "$PROJECT: showcase root ($SHOWCASE_ROOT) is not a git repo — cannot wire submodule."

if [ -e "$SHOWCASE_ROOT/$SM_PATH/.git" ]; then
  # Existing submodule — origin-guard, fetch, checkout the pushed main tip.
  sm_origin="$(git -C "$SHOWCASE_ROOT/$SM_PATH" remote get-url origin 2>/dev/null || echo '')"
  case "$sm_origin" in
    *-rust-mirror*) ;;
    *) die "$PROJECT: submodule $SM_PATH origin '$sm_origin' is not *-rust-mirror — REFUSING to touch it." ;;
  esac
  ( cd "$SHOWCASE_ROOT/$SM_PATH"
    git fetch -q origin main 2>/dev/null && git checkout -q FETCH_HEAD 2>/dev/null || true )
else
  git -C "$SHOWCASE_ROOT" submodule add --force "$MIRROR_URL" "$SM_PATH" >/dev/null 2>&1 \
    || warn "$PROJECT: submodule add reported an issue (may already be registered) — continuing."
fi
git -C "$SHOWCASE_ROOT" add .gitmodules "$SM_PATH" 2>/dev/null || true
# Registered-but-uninitialized submodule (fresh/partial checkout): `submodule
# add` fails and `git add $SM_PATH` stages nothing — stage the gitlink pin
# directly at the tip we just pushed, and VERIFY it landed in the index.
REMOTE_TIP="$(git -C "$WORK" rev-parse HEAD 2>/dev/null || true)"
[ -n "$REMOTE_TIP" ] || REMOTE_TIP="$(git ls-remote "$MIRROR_URL" main | cut -f1)"
[ -n "$REMOTE_TIP" ] || die "$PROJECT: cannot resolve pushed mirror tip for gitlink staging."
if ! git -C "$SHOWCASE_ROOT" ls-files --stage -- "$SM_PATH" | grep -q "^160000 ${REMOTE_TIP}"; then
  git -C "$SHOWCASE_ROOT" update-index --add --cacheinfo "160000,${REMOTE_TIP},${SM_PATH}" \
    || die "$PROJECT: could not stage gitlink $SM_PATH @ ${REMOTE_TIP}."
fi
warn "$PROJECT: submodule $SM_PATH staged in showcase @ ${REMOTE_TIP} (not committed — run_all.sh bundles it)."
echo "[crust-mirror] $PROJECT: done (repo=$REPO_NAME submodule=$SM_PATH)."
exit 0
