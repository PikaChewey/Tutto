#!/bin/zsh
# Measures how much a running app costs while you leave it alone.
#
#   scripts/measure.sh <seconds> <process-name> [<process-name> ...]
#
# For each process, over the window:
#   cpu%       CPU-time delta / wall time (from ps)
#   footprint  physical footprint at the end (what Activity Monitor calls Memory)
#   wakeups/s  idle wakeups per second (from top's cumulative IDLEW counter)
#   power      top's energy-impact score (Activity Monitor's "Energy Impact"), end of window
set -uo pipefail
secs=${1:?seconds}; shift

cputime() {  # seconds of CPU used so far
  ps -o time= -p $1 2>/dev/null | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'
}
topfield() {  # pid, field index counted from the end (1 = MEM, 2 = IDLEW, 3 = POWER)
  echo "$2" | awk -v p=$1 -v f=$3 '$1==p { print $(NF-f+1) }' | tr -cd '0-9.'
}
snapshot() { top -l 1 -stats pid,command,cpu,power,idlew,mem 2>/dev/null }

typeset -A pid cpu0 wake0
top0=$(snapshot)
for name in "$@"; do
  p=$(pgrep -x "$name" | head -1)
  if [[ -z $p ]]; then echo "$name: not running"; continue; fi
  pid[$name]=$p; cpu0[$name]=$(cputime $p); wake0[$name]=$(topfield $p "$top0" 2)
done
sleep $secs
top1=$(top -l 2 -s 1 -stats pid,command,cpu,power,idlew,mem 2>/dev/null | awk '/^PID/{n++} n==2')

printf "%-24s %8s %10s %10s %8s\n" "process" "cpu%" "footprint" "wakeups/s" "power"
for name in ${(k)pid}; do
  p=${pid[$name]}
  c1=$(cputime $p)
  cpu=$(echo "scale=3; (${c1:-0} - ${cpu0[$name]:-0}) * 100 / $secs" | bc)
  fp=$(footprint -p $p 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "Footprint:") { print $(i+1) $(i+2); exit } }')
  w1=$(topfield $p "$top1" 2)
  wakes=$(echo "scale=2; (${w1:-0} - ${wake0[$name]:-0}) / ($secs + 1)" | bc)
  power=$(topfield $p "$top1" 3)
  printf "%-24s %8s %10s %10s %8s\n" "$name" "$cpu" "${fp:-?}" "$wakes" "${power:-?}"
done
