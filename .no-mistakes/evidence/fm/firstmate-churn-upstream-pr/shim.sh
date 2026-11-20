#!/bin/sh
n=${0##*/}
[ -n "$FM_TRACE_LOG" ] && { if [ "$n" = sleep ]; then echo "sleep $*"; else echo "$n"; fi; } >> "$FM_TRACE_LOG"
IFS=:
for d in $FM_TRACE_REALPATH; do
  if [ -x "$d/$n" ]; then exec "$d/$n" "$@"; fi
done
echo "shim: $n not found" >&2; exit 127
