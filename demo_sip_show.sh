#!/usr/bin/env bash
# Relaunch under Bash when invoked through sh/dash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOUND_DIR="${SOUND_DIR:-$SCRIPT_DIR/sound}"
RING_SOUND="${RING_SOUND:-$SOUND_DIR/incoming_call_ringtone.wav}"
CONNECT_SOUND="${CONNECT_SOUND:-$SOUND_DIR/call_connected_tone.wav}"
HANG_SOUND="${HANG_SOUND:-$SOUND_DIR/call_hangup_click.wav}"
SOUND_MIN_CALL_DURATION="${SOUND_MIN_CALL_DURATION:-10}"
SOUND_GUIDE_PAUSE="${SOUND_GUIDE_PAUSE:-3.5}"
SOUND_BURST_PAUSE="${SOUND_BURST_PAUSE:-2.5}"
SOUND_HANG_DELAY="${SOUND_HANG_DELAY:-1.5}"
SOUND_PLAYBACK_DELAY="${SOUND_PLAYBACK_DELAY:-0.6}"

# demo_sip_show.sh - SIP demo with Asterisk + pjsua - hacker mode plus demo effects
# High-level driver that showcases a SIP call flow across LXD containers.

# ---------------- General parameters ----------------
AST_CT="${AST_CT:-asterisk01}"
UAS=( ${UAS:-ua01 ua02} )
UA_PORTS=( ${UA_PORTS:-5061 5062} )
AST_EXT_BASE="${AST_EXT_BASE:-1001}"
AST_SVC_TIME="${AST_SVC_TIME:-600}"
LOG_DIR="${LOG_DIR:-$HOME/sip-tests}"
COUNTDOWN="${COUNTDOWN:-3}"

# ---------------- Deterministic scenario -------------
# Keep calls long enough so the dashboard always sees active channels
DURATION_DEFAULT="${DURATION_DEFAULT:-15}"
SCENARIO=(
  "ua01 600 15"      # ua01 -> time service
  "ua02 1001 15"     # ua02 -> ua01
  "ua01 1002 15"     # ua01 -> ua02
)

# ---------------- Talkative hacker mode --------------
HACKER_MODE="${HACKER_MODE:-on}"
LOOP_COUNT="${LOOP_COUNT:-999}"        # near-continuous bursts by default
CALL_BURST="${CALL_BURST:-5}"
BURST_INTERVAL_MS="${BURST_INTERVAL_MS:-400}"
LOOP_SLEEP="${LOOP_SLEEP:-2}"
RAND_DUR_MIN="${RAND_DUR_MIN:-8}"
RAND_DUR_MAX="${RAND_DUR_MAX:-14}"
STOP_FILE="${STOP_FILE:-$HOME/.sipdemo_stop}"

# ---------------- Audio - download + staging --------
# Try these URLs first; otherwise fall back to /usr/share/sounds/alsa.
# Provide your own list via WAV_URLS="url1 url2 ..."
WAV_URLS="${WAV_URLS:-\
https://cdn.freesound.org/previews/341/341695_5858296-lq.mp3 \
https://cdn.freesound.org/previews/476/476178_10095718-lq.mp3 \
https://file-examples.com/storage/fe2d0d1/2017/11/file_example_WAV_1MG.wav}"

# Note: pjsua cannot play .mp3 files, so we also look for local .wav assets.
WAV_SEARCH_DIRS=( "$HOME" "$HOME/Music" "/usr/share/sounds/alsa" "/usr/share/sounds" )

declare -A PLAY_FILES     # host-side path assigned to each UA
declare -A UA_PLAY_FILES  # path inside the container (pushed under /tmp)
declare -A ROLE_WAVS      # audio per role (ring, connect, hang)
declare -A UA_ROLE_FILES  # container path keyed by UA/role

# ---------------- Colors + utilities ------------------
C1=$'\033[1;36m'; C2=$'\033[1;32m'; C3=$'\033[1;33m'; CR=$'\033[0m'
ok(){   printf "${C2}[OK]${CR} %s\n"   "$*"; }
info(){ printf "${C1}[INFO]${CR} %s\n" "$*"; }
warn(){ printf "${C3}[WARN]${CR} %s\n" "$*"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
ms_to_s(){ awk -v ms="$1" 'BEGIN{printf "%.3f", ms/1000.0}'; }
rand_between(){ awk -v min="$1" -v max="$2" 'BEGIN{srand(); printf("%d", min+int(rand()*(max-min+1)))}'; }

# ---------------- Window placement -------------------
# format COLSxROWS+X+Y - adjust to your screen layout
GEOM_DASH="${GEOM_DASH:-120x30+420+80}"     # dashboard centered
GEOM_LOGS="${GEOM_LOGS:-120x14+420+560}"    # logs below dashboard
GEOM_ASTK="${GEOM_ASTK:-84x24+40+120}"      # asterisk on the left
GEOM_PEER="${GEOM_PEER:-84x24+1300+120}"    # peers on the right
GEOM_UA1="${GEOM_UA1:-90x18+60+600}"        # UA1 lower left
GEOM_UA2="${GEOM_UA2:-90x18+1220+600}"      # UA2 lower right

open_term() {
  # $1 title, $2 script body, $3 geometry (optional), $4 hold=yes|no
  # Launch a disposable helper script inside a graphical terminal window.
  local title="$1" body="$2" geo="${3:-}" hold="${4:-yes}"
  local script
  script=$(mktemp -p "${TMPDIR:-/tmp}" sipdemo_term_XXXXXX.sh)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'trap '\''rm -f "$0"'\'' EXIT\n'
    printf '%s\n' "$body"
    if [[ "$hold" == "yes" ]]; then
      printf '\necho\nread -rp "Press Enter to close..." _\n'
    fi
  } >"$script"
  chmod +x "$script"

  if need_cmd gnome-terminal; then
    gnome-terminal ${geo:+--geometry="$geo"} --title="$title" -- bash "$script" &
  elif need_cmd xterm; then
    xterm ${geo:+-geometry "$geo"} -T "$title" -e bash "$script" &
  else
    echo "No compatible terminal (gnome-terminal or xterm) is available." >&2
    rm -f "$script"
    return 1
  fi
}

# ---------------- Basic sanity checks ----------------
check_prereqs(){
  need_cmd lxc || { echo "missing lxc binary"; exit 1; }
  # Require at least one graphical terminal capable of holding dashboards.
  if ! need_cmd gnome-terminal && ! need_cmd xterm; then
    echo "Install gnome-terminal or xterm to enable the multi-window view."
    exit 1
  fi
}

# ---------------- Cleanup / PBX -------------------
hard_reset_environment() {
  # Stop lingering demo processes so we start from a clean slate.
  info "Cleaning up previous sessions"
  pkill -f "asterisk -rx sip show peers" 2>/dev/null || true
  pkill -f "tail -F $LOG_DIR"            2>/dev/null || true
  pkill -f "lxc exec $AST_CT -- bash -lc asterisk -rvvvvv" 2>/dev/null || true
  for ua in "${UAS[@]}"; do lxc exec "$ua" -- bash -lc "pkill -f pjsua || true" 2>/dev/null || true; done
  rm -f "$STOP_FILE" 2>/dev/null || true
  ok "Cleanup done"
}

prepare_pbx() {
  local dollar='$'
  # Derive PBX address, preserve stock configs, and inject our demo dialplan.
  AST_IP="$(lxc list "$AST_CT" -c4 --format=csv | sed 's/ .*//')"
  [[ -n "$AST_IP" ]] || { echo "Unable to determine Asterisk IP"; exit 1; }
  mkdir -p "$LOG_DIR"
  lxc exec "$AST_CT" -- bash -lc '
    set -e
    [[ -f /etc/asterisk/sip.conf.ok        ]] || cp -a /etc/asterisk/sip.conf        /etc/asterisk/sip.conf.ok
    [[ -f /etc/asterisk/extensions.conf.ok ]] || cp -a /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf.ok
  '
  for ua in "${UAS[@]}"; do
    lxc exec "$AST_CT" -- bash -lc '
      set -e; ua="'"$ua"'"
      awk -v sec="$ua" "
        BEGIN{insec=0; skip=0}
        /^\['"$ua"'\]/{print; insec=1; print \"type=friend\nsecret=\" sec \"\nhost=dynamic\ncontext=from-sip\ndtmfmode=rfc2833\ndisallow=all\nallow=ulaw,alaw\nqualify=yes\"; skip=1; next}
        insec && NF==0{insec=0; next}
        !skip{print}
      " /etc/asterisk/sip.conf > /tmp/sip.new && mv /tmp/sip.new /etc/asterisk/sip.conf
    '
  done
  lxc exec "$AST_CT" -- bash -lc "
    set -e; f=/etc/asterisk/extensions.conf
    grep -q '^[[]from-sip[]]' \"${dollar}f\" || cat >> \"${dollar}f\" <<'EOF'
[from-sip]
exten => $AST_SVC_TIME,1,Gosub(time)
exten => $AST_SVC_TIME,n,Hangup()
include => time

[time]
exten => _X.,30000(time),NoOp(Time: \${EXTEN} \${timezone})
exten => _X.,n,Set(CHANNEL(language)=fr)
exten => _X.,n,Wait(0.25)
exten => _X.,n,Answer()
exten => _X.,n,SayUnixTime(,Europe/Paris,)
exten => _X.,n,Playback(beep)
exten => _X.,n,Return()
EOF
  "
  for i in "${!UAS[@]}"; do
    ext=$(( AST_EXT_BASE + i )); ua="${UAS[$i]}"
    lxc exec "$AST_CT" -- bash -lc "
      f=/etc/asterisk/extensions.conf
      if ! grep -q \"^exten => $ext,1,Dial(SIP/$ua)\" \"${dollar}f\"; then
        echo \"exten => $ext,1,Dial(SIP/$ua)\" >> \"${dollar}f\"
      fi
    "
  done
  lxc exec "$AST_CT" -- bash -lc "asterisk -rx 'sip reload' >/dev/null; asterisk -rx 'dialplan reload' >/dev/null; asterisk -rx 'core set verbose 3' >/dev/null || true"
  ok "PBX ready at $AST_IP"
}

# ---------------- Audio: download + scan ------------
maybe_download_wavs() {
  # Opportunistically download example WAV files when none are staged yet.
  local outdir="$LOG_DIR/wavs"; mkdir -p "$outdir"
  if (( $(ls -1 "$outdir"/*.wav 2>/dev/null | wc -l) >= 2 )); then return 0; fi
  local fetch=""
  if need_cmd curl; then fetch="curl -L --fail --max-time 10 -o"
  elif need_cmd wget; then fetch="wget -T 10 -O"
  else return 0; fi
  info "Attempting to download sample phone sounds (optional)..."
  local i=0
  for url in $WAV_URLS; do
    i=$((i+1)); dst="$outdir/sample_$i"
    # try direct .wav downloads first
    $fetch "${dst}.wav" "$url" 2>/dev/null || true
  done
}

collect_local_wavs() {
  # Locate WAV assets across user directories plus the optional download cache.
  maybe_download_wavs
  local found=()
  for d in "${WAV_SEARCH_DIRS[@]}" "$LOG_DIR/wavs"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -r "$f" ]] && [[ "${f##*.}" =~ [Ww][Aa][Vv] ]] && found+=("$f")
    done < <(find "$d" -type f -iname "*.wav" -print0 2>/dev/null || true)
  done
  echo "${found[@]}"
}

assign_wavs() {
  # Build a mapping between each UA and the audio file it should play.
  local list=( $(collect_local_wavs) )
  local total="${#list[@]}"
  for i in "${!UAS[@]}"; do
    ua="${UAS[$i]}"
    eval "custom=\"\${PLAY_${ua}:-}\""
    if [[ -n "${custom:-}" && -r "$custom" ]]; then
      PLAY_FILES["$ua"]="$custom"
    elif (( total > 0 )); then
      PLAY_FILES["$ua"]="${list[$((i%total))]}"
    else
      PLAY_FILES["$ua"]=""  # no playback file
    fi

    if (( i == 0 )) && [[ -r "$CONNECT_SOUND" ]]; then
      # Force the first agent to play the connection prompt so the story is consistent.
      PLAY_FILES["$ua"]="$CONNECT_SOUND"
    elif (( i == 1 )) && [[ -r "$RING_SOUND" ]]; then
      # Second agent is biased toward ringing audio to simulate an inbound call.
      PLAY_FILES["$ua"]="$RING_SOUND"
    fi

    info "Host audio $ua -> ${PLAY_FILES[$ua]:-(none)}"
  done
}

init_role_wavs() {
  # Remember which host-side WAV implements each logical role.
  ROLE_WAVS=()
  [[ -r "$RING_SOUND"    ]] && ROLE_WAVS[ring]="$RING_SOUND"
  [[ -r "$CONNECT_SOUND" ]] && ROLE_WAVS[connect]="$CONNECT_SOUND"
  [[ -r "$HANG_SOUND"    ]] && ROLE_WAVS[hang]="$HANG_SOUND"
}

stage_wavs_into_uas() {
  # Push host WAV files into each LXD container so pjsua can access them locally.
  UA_ROLE_FILES=()
  for ua in "${UAS[@]}"; do
    host_wav="${PLAY_FILES[$ua]:-}"
    if [[ -n "$host_wav" && -r "$host_wav" ]]; then
      tmp="/tmp/demo_audio_${ua}.wav"
      lxc file push "$host_wav" "$ua$tmp" >/dev/null 2>&1 || true
      UA_PLAY_FILES["$ua"]="$tmp"
      info "Staged audio for $ua -> $tmp"
    else
      UA_PLAY_FILES["$ua"]=""
    fi

    for role in "${!ROLE_WAVS[@]}"; do
      host_role="${ROLE_WAVS[$role]}"
      [[ -n "$host_role" && -r "$host_role" ]] || continue
      remote="/tmp/demo_audio_${role}.wav"
      lxc file push "$host_role" "$ua$remote" >/dev/null 2>&1 || true
      UA_ROLE_FILES["$ua:$role"]="$remote"
    done
  done
}

# ---------------- pjsua builder ---------------------
pjsua_cmd() {
  # Compose the pjsua command for one call, with optional per-call media override.
  local ua="$1" port="$2" target="$3" dur="$4" override_play="${5:-}"
  local play="${override_play:-${UA_PLAY_FILES[$ua]:-}}" rec="/tmp/${ua}_$(date +%H%M%S).wav"
  local play_opt=""; [[ -n "$play" ]] && play_opt="--play-file='$play'"
  cat <<EOF
pjsua --null-audio --log-level=3 --duration=${dur} \
  --local-port=${port} \
  --id=sip:${ua}@$AST_IP --registrar=sip:$AST_IP --realm='*' \
  --username=${ua} --password=${ua} \
  --auto-answer=200 \
  $play_opt --rec-file='${rec}' \
  sip:${target}@$AST_IP
EOF
}

select_call_media() {
  # Decide which audio role should be played for a given UA/target pair.
  local ua="$1" target="$2"

  if [[ -n "${UA_ROLE_FILES[$ua:connect]:-}" && "$target" == "$AST_SVC_TIME" ]]; then
    echo "${UA_ROLE_FILES[$ua:connect]}"
    return
  fi

  for i in "${!UAS[@]}"; do
    local ext=$(( AST_EXT_BASE + i ))
    if [[ "$target" == "$ext" && -n "${UA_ROLE_FILES[$ua:ring]:-}" ]]; then
      echo "${UA_ROLE_FILES[$ua:ring]}"
      return
    fi
  done

  echo ""
}

host_sound_for_target() {
  # Work out which WAV should be played on the host side for this destination.
  local target="$1"
  if [[ "$target" == "$AST_SVC_TIME" && -r "$CONNECT_SOUND" ]]; then
    echo "$CONNECT_SOUND"
    return
  fi
  for i in "${!UAS[@]}"; do
    local ext=$(( AST_EXT_BASE + i ))
    if [[ "$target" == "$ext" && -r "$RING_SOUND" ]]; then
      echo "$RING_SOUND"
      return
    fi
  done
  echo ""
}

target_to_ua() {
  # Translate an extension back to the UA identifier it belongs to.
  local target="$1"
  for i in "${!UAS[@]}"; do
    local ext=$(( AST_EXT_BASE + i ))
    if [[ "$target" == "$ext" ]]; then
      echo "${UAS[$i]}"
      return
    fi
  done
  echo ""
}

host_sound_label() {
  # Provide a human-friendly label for the host playback state.
  local path="$1" can_play="$2"
  local base="none"
  if [[ -z "$path" ]]; then
    base="none"
  elif [[ "$path" == "$CONNECT_SOUND" ]]; then
    base="connect tone"
  elif [[ "$path" == "$RING_SOUND" ]]; then
    base="ring tone"
  elif [[ "$path" == "$HANG_SOUND" ]]; then
    base="hangup click"
  else
    base="custom"
  fi
  if [[ -z "$path" ]]; then
    echo "$base"
  elif [[ "$can_play" == "yes" ]]; then
    echo "$base (host playback)"
  else
    echo "$base (host muted)"
  fi
}

remote_sound_label() {
  # Convert container-side audio paths into role names for the dashboard.
  local ua="$1" audio="$2"
  [[ -n "$audio" ]] || { echo "none"; return; }
  if [[ "${UA_ROLE_FILES[$ua:connect]:-}" == "$audio" ]]; then
    echo "connect tone"
    return
  fi
  if [[ "${UA_ROLE_FILES[$ua:ring]:-}" == "$audio" ]]; then
    echo "ring tone"
    return
  fi
  if [[ "${PLAY_FILES[$ua]:-}" == "$CONNECT_SOUND" ]]; then
    echo "connect tone"
    return
  fi
  if [[ "${PLAY_FILES[$ua]:-}" == "$RING_SOUND" ]]; then
    echo "ring tone"
    return
  fi
  echo "custom"
}

describe_call_step() {
  # Produce a textual summary for the guided scenario dashboard section.
  local idx="$1" total="$2" ua="$3" target="$4" dur="$5" remote_audio="$6" host_audio="$7" can_play="$8"
  local remote_label host_label dest summary
  remote_label=$(remote_sound_label "$ua" "$remote_audio")
  host_label=$(host_sound_label "$host_audio" "$can_play")
  if [[ "$target" == "$AST_SVC_TIME" ]]; then
    summary="Call to time service ($AST_SVC_TIME)"
  else
    dest=$(target_to_ua "$target")
    if [[ -n "$dest" ]]; then
      summary="Inbound call for $dest (ext $target)"
    else
      summary="Call to $target"
    fi
  fi
  printf 'Step %s/%s : %s\n' "$idx" "$total" "$summary"
  printf '  Source      : %s\n' "$ua"
  if [[ "$target" == "$AST_SVC_TIME" ]]; then
    printf '  Destination : Time service (%s)\n' "$AST_SVC_TIME"
  else
    dest=$(target_to_ua "$target")
    if [[ -n "$dest" ]]; then
      printf '  Destination : %s (ext %s)\n' "$dest" "$target"
    else
      printf '  Destination : %s\n' "$target"
    fi
  fi
  printf '  UA audio     : %s\n' "$remote_label"
  printf '  Host audio   : %s\n' "$host_label"
  printf '  Planned dura : %ss\n' "$dur"
}

describe_burst_call() {
  # Same as describe_call_step but tailored for the burst loop.
  local wave="$1" waves_total="$2" call_idx="$3" call_total="$4" ua="$5" target="$6" dur="$7" remote_audio="$8" host_audio="$9" can_play="${10}"
  local dest remote_label host_label
  remote_label=$(remote_sound_label "$ua" "$remote_audio")
  host_label=$(host_sound_label "$host_audio" "$can_play")
  dest=$(target_to_ua "$target")
  printf 'Burst %s/%s - call %s/%s\n' "$wave" "$waves_total" "$call_idx" "$call_total"
  printf '  Source      : %s\n' "$ua"
  if [[ "$target" == "$AST_SVC_TIME" ]]; then
    printf '  Destination : Time service (%s)\n' "$AST_SVC_TIME"
  elif [[ -n "$dest" ]]; then
    printf '  Destination : %s (ext %s)\n' "$dest" "$target"
  else
    printf '  Destination : %s\n' "$target"
  fi
  printf '  UA audio     : %s\n' "$remote_label"
  printf '  Host audio   : %s\n' "$host_label"
  printf '  Planned dura : %ss\n' "$dur"
}

# ---------------- ASCII phone + Dashboard -----------
dashboard_script_body() {
  # Emit the body of the dashboard helper script executed in a terminal.
  local header
  header=$(printf 'AST_CT=%q\nAST_IP=%q\nLOG_DIR=%q\nHACKER_MODE=%q\nSTOP_FILE=%q\nUAS_DISPLAY=%q\n' \
    "$AST_CT" "$AST_IP" "$LOG_DIR" "$HACKER_MODE" "$STOP_FILE" "${UAS[*]}")
  printf '%s\n' "$header"
  cat <<'EOS'
phone_icon() {
cat <<'EOP'
      ____
 ___ / __ \   ☎
|___| |  | |  |
    | |  | |  |
    | |__| |  |
     \____/   |
EOP
}

trap 'tput cnorm 2>/dev/null || true' EXIT
tput civis 2>/dev/null || true

step_file="$HOME/.sipdemo_current_step"; touch "$step_file"
loop_file="$HOME/.sipdemo_loop_state";  touch "$loop_file"

while true; do
  clear
  echo -e "\033[1;36m============================================\033[0m"
  echo -e "\033[1;32m   WELCOME TO THE SWITCHBOARD DASHBOARD\033[0m"
  echo -e "\033[1;36m============================================\033[0m"
  echo
  echo -e "\033[1;33m$(phone_icon)\033[0m"
  echo -e "\033[1;32mPBX:\033[0m ${AST_IP}"
  echo -e "\033[1;32mUAs:\033[0m ${UAS_DISPLAY}"
  echo -e "\033[1;32mLogs:\033[0m ${LOG_DIR}"
  echo -e "\033[1;33mHacker mode:\033[0m ${HACKER_MODE}   \033[1;33mStop file:\033[0m ${STOP_FILE}"
  echo
  echo -e "\033[1;36mWhat you see:\033[0m signaling, active channels, guided scenario, then controlled bursts."
  echo

  echo -e "\033[1;36m=== Scenario status ===\033[0m"
  if [[ -s "$step_file" ]]; then
    cat "$step_file"
  else
    echo "Waiting for the first call..."
  fi

  echo -e "\n\033[1;36m--- PBX snapshot ---\033[0m"
  if ! lxc exec "$AST_CT" -- bash -lc 'asterisk -rx "core show channels concise"' 2>/dev/null; then
    echo "(asterisk command unavailable)"
  fi

  echo -e "\n\033[1;36m--- SIP peers ---\033[0m"
  if ! lxc exec "$AST_CT" -- bash -lc "asterisk -rx 'sip show peers' | egrep 'Name|^ua'" 2>/dev/null; then
    echo "(sip show peers command unavailable)"
  fi

  if [[ -s "$loop_file" ]]; then
    echo -e "\n\033[1;36m--- Hacker mode ---\033[0m"
    tail -n 5 "$loop_file"
  fi

  sleep 2
done
EOS
}

# ---------------- Multi-terminal orchestration -----
run_demo_terms() {
  # Launch dashboards, then walk through the guided scenario and optional bursts.
  local spacing_det="$SOUND_GUIDE_PAUSE"
  local spacing_burst="$SOUND_BURST_PAUSE"
  local host_can_play="no"
  if need_cmd aplay; then host_can_play="yes"; fi

  local dashboard_body logs_body peers_body asterisk_body
  dashboard_body=$(dashboard_script_body)
  open_term "dashboard" "$dashboard_body" "$GEOM_DASH" yes
  sleep 0.4

  # Tail call logs once files start appearing in the log directory.
  logs_body=$(
    {
      printf 'LOG_DIR=%q\n' "$LOG_DIR"
      cat <<'EOS'
mkdir -p "$LOG_DIR"
echo "Waiting for logs..."
while true; do
  if compgen -G "$LOG_DIR"/*.log > /dev/null 2>&1; then
    tail -F "$LOG_DIR"/*.log
    break
  fi
  sleep 2
done
EOS
    }
  )
  open_term "logs" "$logs_body" "$GEOM_LOGS" yes

  # Continuously refresh the SIP peer list in its own pane.
  peers_body=$(
    {
      printf 'AST_CT=%q\n' "$AST_CT"
      cat <<'EOS'
while true; do
  clear
  if ! lxc exec "$AST_CT" -- bash -lc "asterisk -rx 'sip show peers' | egrep 'Name|^ua'" 2>/dev/null; then
    echo "(sip show peers command unavailable)"
  fi
  sleep 2
done
EOS
    }
  )
  open_term "peers" "$peers_body" "$GEOM_PEER" yes

  # Dedicated interactive console for raw Asterisk commands.
  asterisk_body=$(
    {
      printf 'AST_CT=%q\n' "$AST_CT"
      cat <<'EOS'
lxc exec "$AST_CT" -- bash -lc "asterisk -rvvvvv"
EOS
    }
  )
  open_term "asterisk" "$asterisk_body" "$GEOM_ASTK" yes

  local idx ua geom_var geom ua_body
  # Spawn a holding terminal for each UA to keep layouts consistent.
  for idx in "${!UAS[@]}"; do
    ua=${UAS[$idx]}
    geom_var="GEOM_UA$((idx+1))"
    geom=${!geom_var:-}
    ua_body=$(
      {
        printf 'message=%q\n' "$ua ready - waiting for automated calls"
        cat <<'EOS'
echo "$message"
while true; do sleep 3600; done
EOS
      }
    )
    open_term "$ua" "$ua_body" "$geom" yes
  done

  for s in $(seq "$COUNTDOWN" -1 1); do
    echo "Starting in $s..."
    sleep 1
  done
  echo "Action!"

  local step_file="$HOME/.sipdemo_current_step"; : > "$step_file"

  local total_steps=${#SCENARIO[@]}
  local step_idx=0
  # Guided scenario: execute each scripted call sequentially.
  for line in "${SCENARIO[@]}"; do
    step_idx=$((step_idx+1))
    set -- $line; ua=${1}; target=${2}
    set -- $line; dur=${3:-0}
    [[ "$dur" == "0" ]] && dur="$DURATION_DEFAULT"
    if (( dur < SOUND_MIN_CALL_DURATION )); then
      dur=$SOUND_MIN_CALL_DURATION
    fi

    local ua_idx=-1 i port cmd_payload call_body
    for i in "${!UAS[@]}"; do
      if [[ "${UAS[$i]}" == "$ua" ]]; then
        ua_idx=$i
        break
      fi
    done
    if (( ua_idx < 0 )); then
      echo "Unknown UA $ua"
      continue
    fi
    port="${UA_PORTS[$ua_idx]}"

    local media_override=""
    media_override=$(select_call_media "$ua" "$target")
    cmd_payload=$(pjsua_cmd "$ua" "$port" "$target" "$dur" "$media_override")

    local remote_audio="$media_override"
    if [[ -z "$remote_audio" ]]; then
      remote_audio="${UA_PLAY_FILES[$ua]:-}"
    fi

    local host_sound=""
    host_sound=$(host_sound_for_target "$target")

    local step_desc
    step_desc=$(describe_call_step "$step_idx" "$total_steps" "$ua" "$target" "$dur" "$remote_audio" "$host_sound" "$host_can_play")
    printf '%s\n' "$step_desc" > "$step_file"

    if [[ "$host_can_play" == yes && -n "$host_sound" ]]; then
      aplay "$host_sound" >/dev/null 2>&1 || true
      sleep "$SOUND_PLAYBACK_DELAY"
    fi

    call_body=$(
      {
        printf 'UA=%q\nTARGET=%q\nLOG_DIR=%q\n' "$ua" "$target" "$LOG_DIR"
        printf 'cmd=%q\n' "$cmd_payload"
        printf 'HANG_SOUND=%q\n' "$HANG_SOUND"
        printf 'HOST_CAN_PLAY=%q\n' "$host_can_play"
        printf 'SOUND_HANG_DELAY=%q\n' "$SOUND_HANG_DELAY"
        cat <<'EOS'
ts=$(date +%Y%m%d_%H%M%S)
lxc exec "$UA" -- bash -lc "$cmd" | tee "$LOG_DIR/${UA}_${ts}_to_${TARGET}.log"
if [[ "$HOST_CAN_PLAY" == yes && -n "$HANG_SOUND" && -r "$HANG_SOUND" ]]; then
  aplay "$HANG_SOUND" >/dev/null 2>&1 || true
  sleep "$SOUND_HANG_DELAY"
fi
EOS
      }
    )
    open_term "$ua: call $target" "$call_body" "" no
    sleep "$spacing_det"
  done

  if [[ "$HACKER_MODE" == "on" ]]; then
    # Optional burst mode to stress the PBX with randomized call storms.
    local loop_file="$HOME/.sipdemo_loop_state"; : > "$loop_file"
    echo "Hacker mode: $LOOP_COUNT waves x $CALL_BURST calls" >> "$loop_file"
    echo "Stop file: $STOP_FILE" >> "$loop_file"

    local wave
    for wave in $(seq 1 "$LOOP_COUNT"); do
      if [[ -f "$STOP_FILE" ]]; then
        echo "STOP requested" > "$loop_file"
        break
      fi
      echo "Wave $wave/$LOOP_COUNT" > "$loop_file"

      local n
      for n in $(seq 1 "$CALL_BURST"); do
        [[ -f "$STOP_FILE" ]] && break
        local src_idx src dst dur port cmd_payload burst_body
        src_idx=$(rand_between 0 $((${#UAS[@]}-1)))
        src="${UAS[$src_idx]}"
        case "$(rand_between 0 2)" in
          0) dst="$AST_SVC_TIME" ;;
          1) dst="$(( AST_EXT_BASE + src_idx ))" ;;
          2) dst="$(( AST_EXT_BASE + ((src_idx+1)%${#UAS[@]}) ))" ;;
        esac
        dur=$(rand_between "$RAND_DUR_MIN" "$RAND_DUR_MAX")
        if (( dur < SOUND_MIN_CALL_DURATION )); then
          dur=$SOUND_MIN_CALL_DURATION
        fi
        port="${UA_PORTS[$src_idx]}"

        echo "burst: $src -> $dst (${dur}s)" >> "$loop_file"

        local media_override=""
        media_override=$(select_call_media "$src" "$dst")
        cmd_payload=$(pjsua_cmd "$src" "$port" "$dst" "$dur" "$media_override")

        local remote_audio="$media_override"
        if [[ -z "$remote_audio" ]]; then
          remote_audio="${UA_PLAY_FILES[$src]:-}"
        fi

        local host_sound=""
        host_sound=$(host_sound_for_target "$dst")

        local burst_desc
        burst_desc=$(describe_burst_call "$wave" "$LOOP_COUNT" "$n" "$CALL_BURST" "$src" "$dst" "$dur" "$remote_audio" "$host_sound" "$host_can_play")
        printf '%s\n' "$burst_desc" > "$step_file"

        if [[ "$host_can_play" == yes && -n "$host_sound" ]]; then
          aplay "$host_sound" >/dev/null 2>&1 || true
          sleep "$SOUND_PLAYBACK_DELAY"
        fi
        burst_body=$(
          {
            printf 'UA=%q\nTARGET=%q\nLOG_DIR=%q\n' "$src" "$dst" "$LOG_DIR"
            printf 'cmd=%q\n' "$cmd_payload"
            printf 'HANG_SOUND=%q\n' "$HANG_SOUND"
            printf 'HOST_CAN_PLAY=%q\n' "$host_can_play"
            printf 'SOUND_HANG_DELAY=%q\n' "$SOUND_HANG_DELAY"
            cat <<'EOS'
ts=$(date +%Y%m%d_%H%M%S)
lxc exec "$UA" -- bash -lc "$cmd" | tee "$LOG_DIR/${UA}_${ts}_burst_to_${TARGET}.log"
if [[ "$HOST_CAN_PLAY" == yes && -n "$HANG_SOUND" && -r "$HANG_SOUND" ]]; then
  aplay "$HANG_SOUND" >/dev/null 2>&1 || true
  sleep "$SOUND_HANG_DELAY"
fi
EOS
          }
        )
        open_term "$src: burst -> $dst" "$burst_body" "" no
        sleep "$spacing_burst"
      done

      [[ -f "$STOP_FILE" ]] && break
      sleep "$LOOP_SLEEP"
    done
    echo "Hacker mode complete" >> "$loop_file"
  fi

  echo "Demo finished. Call windows close automatically. Dashboard and log panes stay open."
}

# ---------------- Main ----------------
check_prereqs
hard_reset_environment
prepare_pbx
init_role_wavs
assign_wavs
stage_wavs_into_uas
run_demo_terms
