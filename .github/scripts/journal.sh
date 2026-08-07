#!/usr/bin/env bash
# =============================================================================
#  Daily Journal automation.
#  Creates between MIN_COMMITS and MAX_COMMITS (default 1-11) journal entries
#  per day using a rotating pool of ~200 entry lines that are shuffled on a
#  deterministic per-day seed. Entries are timestamped at random points across
#  the day so the commit history looks natural instead of bursty.
#
#  Designed to run once per day from a GitHub Actions scheduled workflow.
# =============================================================================
set -euo pipefail

BOT_NAME="${BOT_NAME:-Your Name}"
BOT_EMAIL="${BOT_EMAIL:-you@users.noreply.github.com}"
BOT_TZ="${BOT_TZ:-UTC}"
MIN_COMMITS="${MIN_COMMITS:-1}"
MAX_COMMITS="${MAX_COMMITS:-11}"
SKIP_CHANCE="${SKIP_CHANCE:-0}"     # 0-100: % chance of an inactive day
SKIP_WEEKENDS="${SKIP_WEEKENDS:-0}" # 1 = never commit on Sat/Sun
SEED_SALT="${SEED_SALT:-}"          # extra salt so multi-repo shuffles differ

REPO_ROOT="$(git rev-parse --show-toplevel)"
MESSAGES_FILE="$REPO_ROOT/.github/data/entries.txt"
JOURNAL="$REPO_ROOT/journal.md"
STATE_FILE="$REPO_ROOT/.github/data/.last-run"

export TZ="$BOT_TZ"

TODAY="$(date +%Y-%m-%d)"
SEED="$(date +%Y%m%d)${SEED_SALT}"

# ---------------------------------------------------------------------------
#  Guard: run only once per day (prevents duplicate commits on re-runs)
# ---------------------------------------------------------------------------
if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$TODAY" ]; then
  echo "[journal] Already ran today ($TODAY). Nothing to do."
  exit 0
fi

# ---------------------------------------------------------------------------
#  Optional realism knobs: occasionally take a day off
# ---------------------------------------------------------------------------
if [ "$SKIP_WEEKENDS" = "1" ]; then
  DOW="$(date -d "$TODAY" +%u)"
  if [ "$DOW" = "6" ] || [ "$DOW" = "7" ]; then
    echo "[journal] Skipping weekend ($TODAY)."
    exit 0
  fi
fi

if [ "$SKIP_CHANCE" -gt 0 ]; then
  roll=$(( RANDOM % 100 ))
  if (( roll < SKIP_CHANCE )); then
    echo "[journal] Taking a random day off (roll $roll < $SKIP_CHANCE%)."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
#  How many entries today? (default 1 to 11)
# ---------------------------------------------------------------------------
if [ "$MAX_COMMITS" -lt "$MIN_COMMITS" ]; then
  echo "[journal] MAX_COMMITS < MIN_COMMITS, clamping."
  MAX_COMMITS="$MIN_COMMITS"
fi
NUM_COMMITS=$(( MIN_COMMITS + (RANDOM % (MAX_COMMITS - MIN_COMMITS + 1)) ))
echo "[journal] Planning $NUM_COMMITS entry commit(s) for $TODAY"

# ---------------------------------------------------------------------------
#  Deterministic daily shuffle of the entry pool.
#  Seeded with the date -> stable within a day, different every day.
# ---------------------------------------------------------------------------
TMP_SHUF="$(mktemp)"
while IFS= read -r msg; do
  msg="${msg//$'\r'/}"
  [ -z "$msg" ] && continue
  h="$(printf '%s|%s' "$SEED" "$msg" | sha256sum | awk '{print $1}')"
  printf '%s\t%s\n' "$h" "$msg"
done < "$MESSAGES_FILE" | LC_ALL=C sort | cut -f2- > "$TMP_SHUF"

mapfile -t MSGS < "$TMP_SHUF"
rm -f "$TMP_SHUF"

TOTAL="${#MSGS[@]}"
if [ "$TOTAL" -eq 0 ]; then
  echo "[journal] No entry lines found. Aborting."
  exit 1
fi

# Rotate the start pointer by the day index so entries are not reused until
# the whole pool has cycled through.
DAYS_SINCE_EPOCH=$(( $(date +%s) / 86400 ))
START_IDX=$(( DAYS_SINCE_EPOCH % TOTAL ))

# ---------------------------------------------------------------------------
#  Build entry timestamps spread across the day.
#  First entry lands between 08:00 and 13:00, then gaps of 20-80 minutes.
# ---------------------------------------------------------------------------
START_HOUR=$(( (RANDOM % 6) + 8 ))
START_MIN=$(( RANDOM % 60 ))
NOW_EPOCH="$(date +%s)"
START_EPOCH="$(date -d "$TODAY ${START_HOUR}:${START_MIN}:00" +%s)"

# ---------------------------------------------------------------------------
#  Configure commit identity
# ---------------------------------------------------------------------------
git config user.name  "$BOT_NAME"
git config user.email "$BOT_EMAIL"

# ---------------------------------------------------------------------------
#  Make the commits
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$JOURNAL")"
if [ ! -f "$JOURNAL" ]; then
  printf '# Journal\n\n' > "$JOURNAL"
fi

# Pre-compute the schedule so gaps are preserved even if we must back-date it
# (e.g. the workflow runs before the 08:00 window, or is delayed).
epochs=()
e="$START_EPOCH"
for (( i = 0; i < NUM_COMMITS; i++ )); do
  epochs+=("$e")
  e=$(( e + 60 * ( (RANDOM % 61) + 20 ) ))
done

# Never stamp any commit in the future: shift the whole day's schedule back so
# the last commit lands right at "now", keeping the intra-day gaps intact.
LAST="${epochs[$((NUM_COMMITS - 1))]}"
if (( LAST > NOW_EPOCH )); then
  shift=$(( LAST - NOW_EPOCH ))
  for (( i = 0; i < NUM_COMMITS; i++ )); do
    epochs[$i]=$(( ${epochs[$i]} - shift ))
  done
fi

for (( i = 0; i < NUM_COMMITS; i++ )); do
  msg="${MSGS[$(( (START_IDX + i) % TOTAL ))]}"
  epoch="${epochs[$i]}"

  local_ts="$(date -d "@$epoch" +'%Y-%m-%d %H:%M')"
  author_date="$(date -u -d "@$epoch" +'%Y-%m-%dT%H:%M:%S%z')"

  printf -- '- %s - %s\n' "$local_ts" "$msg" >> "$JOURNAL"

  git add "$JOURNAL"
  git commit -q -m "$msg" --date="$author_date"
  echo "[journal] committed: $msg ($local_ts)"
done

# remember that we ran today (write only after successful commits)
printf '%s\n' "$TODAY" > "$STATE_FILE"

echo "[journal] Done. $NUM_COMMITS entry commit(s) created."
