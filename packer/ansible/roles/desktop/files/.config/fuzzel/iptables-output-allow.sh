#!/bin/bash

if [ -z "${1}" ]; then
  read LOG
else
  LOG="${1}"
fi

if [ -z "${LOG}" ]; then
  LOG=$(sudo tail -n 1 /var/log/iptables_output_user.log)
fi

parse_field() { echo "$1" | grep -oP "${2}=\K\S+"; }

PROTO=$(parse_field "$LOG" "PROTO")
SRC=$(parse_field   "$LOG" "SRC")
DST=$(parse_field   "$LOG" "DST")
SPT=$(parse_field   "$LOG" "SPT")
DPT=$(parse_field   "$LOG" "DPT")
OUT=$(parse_field   "$LOG" "OUT")

# Validate required fields
MISSING=()
[ -z "$SRC"   ] && MISSING+=("SRC")
[ -z "$DST"   ] && MISSING+=("DST")
[ -z "$DPT"   ] && MISSING+=("DPT")
[ -z "$PROTO" ] && MISSING+=("PROTO")
[ -z "$OUT"   ] && MISSING+=("OUT")

if [ ${#MISSING[@]} -gt 0 ]; then
  MISSING_STR=$(IFS=", "; echo "${MISSING[*]}")
  notify-send "iptables parser ✗" "Missing fields: ${MISSING_STR}\n\nLog line:\n${LOG}"
  exit 1
fi

OPTIONS="Allow $SRC -> $DST:$DPT ($PROTO) on $OUT
Allow all from $SRC on $OUT
Allow all to $DST:$DPT ($PROTO)
Cancel"

CHOICE=$(echo "$OPTIONS" | fuzzel --width=60 --dmenu --prompt "Allow blocked traffic? ")

case "$CHOICE" in
  "Allow $SRC -> $DST:$DPT ($PROTO) on $OUT")
    CMD="iptables -I OUTPUT -o $OUT -p ${PROTO} -s $SRC -d $DST --dport $DPT -j ACCEPT"
    ;;
  "Allow all from $SRC on $OUT")
    CMD="iptables -I OUTPUT -o $OUT -s $SRC -j ACCEPT"
    ;;
  "Allow all to $DST:$DPT ($PROTO)")
    CMD="iptables -I OUTPUT -o $OUT -p ${PROTO} -d $DST --dport $DPT -j ACCEPT"
    ;;
  *)
    notify-send "iptables" "No rule applied."
    exit 0
    ;;
esac

if sudo $CMD; then
  notify-send "iptables ✓" "$CMD"
else
  notify-send "iptables ✗" "$CMD"
fi
