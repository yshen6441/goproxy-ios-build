#!/bin/sh
CTL=/var/mobile/.config/mihomo/.ctl
STATUS=/var/mobile/.config/mihomo/.status
MIHOMO_PLIST=/var/jb/Library/LaunchDaemons/com.metacubex.mihomo.plist
LABEL=com.metacubex.mihomo

mihomo_running() {
  /bin/launchctl print system/$LABEL >/dev/null 2>&1
}

set_status() {
  echo "$1" > "$STATUS"
}

while true; do
  if [ -f "$CTL" ]; then
    CMD=$(/bin/cat "$CTL")
    /bin/rm -f "$CTL"
    case "$CMD" in
      start)
        if mihomo_running; then
          set_status running
        else
          /bin/launchctl bootstrap system "$MIHOMO_PLIST" >/dev/null 2>&1
          if mihomo_running; then
            set_status running
          else
            set_status error
          fi
        fi
        ;;
      stop)
        /bin/launchctl bootout system/$LABEL >/dev/null 2>&1
        if mihomo_running; then
          set_status running
        else
          set_status stopped
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
