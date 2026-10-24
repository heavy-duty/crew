# shared/lib/host/pause.sh — the one copy of the pause and resume shell (#284,
# #759). A paused box keeps its crontab, every live tick.sh line commented
# with the marker; resume uncomments exactly those. cli/crew sources this
# file and runs the scripts over box exec; the floor's actions.py reads the
# same two blocks out of this file between the markers below, so there is
# exactly one copy and a test reds a second (#284's acceptance).
#
# shellcheck shell=bash


host_pause_sh() {
  cat <<'PAUSE_SH'
# ---PAUSE_SH---
cron="$(crontab -l 2>/dev/null || true)"
armed="$(printf '%s\n' "$cron" | grep -cE '^[^#].*tick\.sh' || true)"
[ "$armed" -gt 0 ] || { echo "nothing to pause: no armed tick.sh line"; exit 0; }
was="$(printf '%s\n' "$cron" | grep -c '^#CREW-FLOOR-PAUSED' || true)"
printf '%s\n' "$cron" | sed -E 's|^([^#].*tick\.sh.*)$|#CREW-FLOOR-PAUSED \1|' | crontab - \
  || { echo "pause: crontab write failed" >&2; exit 1; }
now="$(crontab -l 2>/dev/null | grep -c '^#CREW-FLOOR-PAUSED' || true)"
[ "$(( now - was ))" -eq "$armed" ] \
  || { echo "pause: crontab write reported success, $(( now - was )) of $armed lines are commented" >&2; exit 1; }
echo "paused $armed"
# ---END---
PAUSE_SH
}

host_resume_sh() {
  cat <<'RESUME_SH'
# ---RESUME_SH---
cron="$(crontab -l 2>/dev/null || true)"
paused="$(printf '%s\n' "$cron" | grep -c '^#CREW-FLOOR-PAUSED' || true)"
[ "$paused" -gt 0 ] || { echo "nothing to resume: no paused tick.sh line"; exit 0; }
was="$(printf '%s\n' "$cron" | grep -cE '^[^#].*tick\.sh' || true)"
printf '%s\n' "$cron" | sed -E 's|^#CREW-FLOOR-PAUSED ||' | crontab - \
  || { echo "resume: crontab write failed" >&2; exit 1; }
now="$(crontab -l 2>/dev/null | grep -cE '^[^#].*tick\.sh' || true)"
[ "$(( now - was ))" -eq "$paused" ] \
  || { echo "resume: crontab write reported success, $(( now - was )) of $paused lines are live" >&2; exit 1; }
echo "resumed $paused"
# ---END---
RESUME_SH
}
