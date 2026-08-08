#!/bin/sh
CONFIG_DIR=/var/mobile/.config/mihomo
CTL=$CONFIG_DIR/.ctl
STATUS=$CONFIG_DIR/.status
LOG=$CONFIG_DIR/helper.log
MIHOMO_PLIST=/var/jb/Library/LaunchDaemons/com.metacubex.mihomo.plist
LABEL=com.metacubex.mihomo
UID_NUM=$(/usr/bin/id -u)

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

mihomo_running() {
  /bin/launchctl print user/$UID_NUM/$LABEL >/dev/null 2>&1
}

set_status() {
  echo "$1" > "$STATUS"
}

log "helper started uid=$UID_NUM"

while true; do
  if [ -f "$CTL" ]; then
    CMD=$(/bin/cat "$CTL")
    /bin/rm -f "$CTL"
    log "cmd=$CMD"
    case "$CMD" in
      start)
        if mihomo_running; then
          set_status running
          log "already running"
        else
          /bin/launchctl bootstrap user/$UID_NUM "$MIHOMO_PLIST" >/dev/null 2>&1
          if mihomo_running; then
            set_status running
            log "start ok"
          else
            set_status error
            log "start failed"
          fi
        fi
        ;;
      stop)
        /bin/launchctl bootout user/$UID_NUM/$LABEL >/dev/null 2>&1
        if mihomo_running; then
          set_status running
          log "stop failed"
        else
          set_status stopped
          log "stop ok"
        fi
        ;;
      restart)
        /bin/launchctl bootout user/$UID_NUM/$LABEL >/dev/null 2>&1
        /bin/launchctl bootstrap user/$UID_NUM "$MIHOMO_PLIST" >/dev/null 2>&1
        if mihomo_running; then
          set_status running
          log "restart ok"
        else
          set_status error
          log "restart failed"
        fi
        ;;
      status)
        if mihomo_running; then
          set_status running
        else
          set_status stopped
        fi
        ;;
    esac
  fi
  /bin/sleep 1
done
