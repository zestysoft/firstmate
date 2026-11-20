/usr/bin/stat() { echo stat >> "$FM_TRACE_LOG"; command /usr/bin/stat "$@"; }
/usr/bin/env() { echo env >> "$FM_TRACE_LOG"; command /usr/bin/env "$@"; }
/bin/ps() { echo ps >> "$FM_TRACE_LOG"; command /bin/ps "$@"; }
/usr/bin/ps() { echo ps >> "$FM_TRACE_LOG"; command /usr/bin/ps "$@"; }
/bin/sleep() { echo "sleep $*" >> "$FM_TRACE_LOG"; command /bin/sleep "$@"; }
/bin/bash() { echo bash >> "$FM_TRACE_LOG"; command /bin/bash "$@"; }
