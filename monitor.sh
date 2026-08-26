#!/bin/bash
# Monitor IMAX Theatre (Norcenter) movie listings on entradas.todoshowcase.com.
# Alerts via Telegram when NEW movies appear in the cartelera — and when the monitor itself breaks.
#
# Config (env vars, or put them in .env next to this script):
#   TELEGRAM_BOT_TOKEN   required for alerts (get from @BotFather)
#   TELEGRAM_CHAT_ID     required for alerts (your chat/user id)
#   CINE                 override target cinema (default: 18 = IMAX Theatre Norcenter)
#   STATE_FILE           known-movies store (default: ./state/known_movies.tsv)
#   ALERT_EVERY          during an outage, re-alert every N failed runs (default 12)
#   HEARTBEAT            set to 1 to force --verbose (handy from cron env)
#
# Flags:
#   --test      fetch + print current movies, no state/alerts
#   --verbose   send a 💓 Telegram heartbeat on EVERY run (success or failure),
#               so silence means "not running". (More messages; drop it once confident.)
#
# Exit: 0 ok, 2 failure (state untouched; Telegram error alert sent w/ throttling)
set -uo pipefail   # NOTE: no -e; we handle errors explicitly so we can alert on them

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/.env" ] && set -a && . "$SCRIPT_DIR/.env" && set +a

TEST=0; VERBOSE=0
[ "${HEARTBEAT:-0}" = 1 ] && VERBOSE=1
for arg in "$@"; do
  case "$arg" in
    --test)            TEST=1 ;;
    --verbose|--heartbeat) VERBOSE=1 ;;
    *) echo "unknown flag: $arg (use --test / --verbose)" >&2; exit 64 ;;
  esac
done

URL='https://entradas.todoshowcase.com/showcase/boleteria.aspx'
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36'
CINE="${CINE:-18}"        # IMAX Theatre (Norcenter)
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/state/known_movies.tsv}"
FAIL_FILE="${STATE_FILE}.failcount"
ALERT_EVERY="${ALERT_EVERY:-12}"

JAR=$(mktemp); TMP=$(mktemp); MOVIES=$(mktemp)
trap 'rm -f "$JAR" "$TMP" "$MOVIES"' EXIT

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

hid_html()  { perl -ne 'print $1 and exit if /id="'"$1"'"[^>]*value="([^"]*)"/' "$2"; }
hid_delta() { perl -ne 'print $1 and exit if /\|hiddenField\|'"$1"'\|([^|]*)/' "$2"; }

# telegram TEXT -> returns 0 on send (or when no creds configured), 1 on real failure
telegram() {
  local text="$1" resp
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log "WARN: no Telegram creds — would have sent:"; printf '%s\n' "$text"; return 0
  fi
  resp=$(curl -s --max-time 30 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$text" \
    --data-urlencode "disable_web_page_preview=true")
  if printf '%s' "$resp" | grep -q '"ok":true'; then log "telegram sent"; return 0; fi
  log "ERROR: telegram send failed: $resp"; return 1
}

# Record a failure, alert on Telegram with throttling, then exit 2.
fail() {
  local reason="$1" n
  n=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
  mkdir -p "$(dirname "$FAIL_FILE")"; echo "$n" > "$FAIL_FILE"
  log "FAILURE #$n: $reason"
  if [ "$VERBOSE" = 1 ] || [ "$n" -eq 1 ] || [ $(( n % ALERT_EVERY )) -eq 0 ]; then
    telegram "⚠️ Monitor IMAX Norcenter con problemas (fallo #$n).
Motivo: $reason
Host: $(hostname)
Reintenta en el próximo ciclo. No pude leer la cartelera, así que no perdiste ninguna alerta."
  else
    log "(alert throttled; next re-alert at multiple of $ALERT_EVERY)"
  fi
  exit 2
}

post() {  # post TARGET FIELD=VAL ...  -> body on stdout; returns curl's exit code
  local target="$1"; shift
  local args=(
    --data-urlencode "ctl00\$Contenido\$GeneralToolkitScriptManager=ctl00\$Contenido\$ctl00|$target"
    --data-urlencode "ctl00_Contenido_GeneralToolkitScriptManager_HiddenField="
  )
  local kv
  for kv in "$@"; do args+=( --data-urlencode "ctl00\$Contenido\$${kv%%=*}=${kv#*=}" ); done
  args+=(
    --data-urlencode "__LASTFOCUS=" --data-urlencode "__EVENTTARGET=$target" --data-urlencode "__EVENTARGUMENT="
    --data-urlencode "__VIEWSTATE=$VS" --data-urlencode "__VIEWSTATEGENERATOR=$VG"
    --data-urlencode "__EVENTVALIDATION=$EV" --data-urlencode "__ASYNCPOST=true"
  )
  curl -s --max-time 30 -b "$JAR" -c "$JAR" -A "$UA" "$URL" \
    -H 'X-MicrosoftAjax: Delta=true' -H 'X-Requested-With: XMLHttpRequest' \
    -H "Origin: https://entradas.todoshowcase.com" -H "Referer: $URL" "${args[@]}"
}

# Walk the cascade; write "id\tname" pairs to $MOVIES. On any problem, calls fail() (exits).
fetch_movies() {
  local code
  code=$(curl -s --max-time 30 -w '%{http_code}' -c "$JAR" -A "$UA" "$URL" -o "$TMP") \
    || fail "network error on initial GET (curl exit $?)"
  [ "$code" = 200 ] || fail "HTTP $code on initial GET"
  VS=$(hid_html __VIEWSTATE "$TMP"); VG=$(hid_html __VIEWSTATEGENERATOR "$TMP"); EV=$(hid_html __EVENTVALIDATION "$TMP")
  [ -n "$VS" ] || fail "no __VIEWSTATE on initial page (site changed / blocked?)"

  post 'ctl00$Contenido$lstCinemaFull' "lstCinemaFull=$CINE" > "$TMP" || fail "curl error at cinema step"
  VS=$(hid_delta __VIEWSTATE "$TMP"); VG=$(hid_delta __VIEWSTATEGENERATOR "$TMP"); EV=$(hid_delta __EVENTVALIDATION "$TMP")
  [ -n "$VS" ] || fail "cascade failed at cinema step (error page / cinema id $CINE gone?)"

  # Parse lstMovies options: <option value="ID">NAME</option>. Decode HTML entities
  # (numeric + common named) so titles read naturally in Telegram.
  perl -CS -0777 -ne '
    if (/id="ctl00_Contenido_lstMovies".*?<\/select>/s) {
      my $b=$&;
      while ($b =~ /<option value="([^"]*)"[^>]*>([^<]*)<\/option>/g) {
        my ($v,$t)=($1,$2);
        next if $v =~ /Seleccione/i || $t =~ /Seleccione/i;
        $t =~ s/&#(\d+);/chr($1)/ge;
        $t =~ s/&amp;/&/g; $t =~ s/&quot;/"/g; $t =~ s/&apos;/'"'"'/g;
        $t =~ s/&lt;/</g;  $t =~ s/&gt;/>/g;
        $t =~ s/^\s+|\s+$//g;
        print "$v\t$t\n";
      }
    }' "$TMP" | sed '/^$/d' > "$MOVIES"
  [ -s "$MOVIES" ] || fail "zero movies parsed for cinema $CINE (cinema removed, or lstMovies markup changed)"
}

# ---- main ----
fetch_movies   # exits via fail() on any error
COUNT=$(grep -c . "$MOVIES")

if [ "$TEST" = 1 ]; then
  log "current movies ($COUNT):"; cat "$MOVIES"; exit 0
fi

# We got a good read. If we were previously broken, announce recovery.
PREV_FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
if [ "$PREV_FAILS" -gt 0 ]; then
  log "recovered after $PREV_FAILS failed run(s)"
  telegram "✅ Monitor IMAX Norcenter recuperado (tras $PREV_FAILS fallo(s)). Leyendo $COUNT películas de nuevo."
fi
rm -f "$FAIL_FILE"

mkdir -p "$(dirname "$STATE_FILE")"

if [ ! -f "$STATE_FILE" ]; then
  # Baseline: dedupe by id, sort numerically for stability.
  awk -F'\t' '!seen[$1]++' "$MOVIES" | sort -t$'\t' -k1,1n > "$STATE_FILE"
  log "baseline saved ($COUNT movies)"
  TITLES=$(cut -f2 "$STATE_FILE" | sed 's/^/• /')
  telegram "🎬 Monitor IMAX Norcenter iniciado. Siguiendo $COUNT películas:
$TITLES

Te aviso cuando agreguen una nueva."
  exit 0
fi

# NEW = rows in $MOVIES whose id is not already in $STATE_FILE.
NEW=$(awk -F'\t' 'NR==FNR{seen[$1]=1;next} !seen[$1]' "$STATE_FILE" "$MOVIES")
if [ -n "$NEW" ]; then
  NCOUNT=$(printf '%s\n' "$NEW" | grep -c .)
  NEW_TITLES=$(printf '%s\n' "$NEW" | cut -f2 | sed 's/^/• /')
  log "NEW movies ($NCOUNT):"; printf '%s\n' "$NEW"
  if telegram "🎟️ ¡Nueva(s) película(s) en IMAX Norcenter! ($NCOUNT)
$NEW_TITLES

Cartelera: $URL"; then
    # Only mark known AFTER a successful alert, so a Telegram hiccup retries next run.
    cat "$STATE_FILE" "$MOVIES" | awk -F'\t' '!seen[$1]++' | sort -t$'\t' -k1,1n > "$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    log "alert not delivered — NOT updating state; will retry next run"
    exit 2
  fi
  STATUS="🎟️ $NCOUNT nueva(s)"
else
  log "no new movies ($COUNT current)"
  STATUS="sin novedades"
fi

if [ "$VERBOSE" = 1 ]; then
  LAST=$(tail -1 "$MOVIES" | cut -f2)
  telegram "💓 Monitor OK ($(hostname)) — $COUNT películas (última: $LAST). $STATUS. $(date '+%H:%M')"
fi
