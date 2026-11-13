#!/bin/sh
# run.sh: zuul-executor with a bounded stop (../README.md, "Stopping the executor"). The pod runs it
# under dumb-init --single-child, so SIGTERM comes here alone.
#
# On SIGTERM this forwards SIGTERM to zuul-executor, whose own handler stops it gracefully
# (zuul.conf, sigterm_method): it takes no new builds and lets the running ones finish. That needs
# ZooKeeper. Without it, Zuul 14's stop fails in the signal handler (SessionExpiredError) and the
# process would run on, so this stops it hard (SIGKILL) as soon as ZooKeeper has not answered
# twice in a row, 5 seconds apart, and in any case at the deadline, below the pod's grace period.
# A build killed that way fails, and Zuul runs it again.
#
# The variables are for ../check.sh's test of it, which runs a stand-in for zuul-executor.
# shellcheck disable=SC2329 # stop runs from the trap, and calls the other functions
set -u

deadline=${ZUUL_STOP_DEADLINE:-1740}
zookeeper_host=${ZUUL_STOP_ZOOKEEPER_HOST:-zookeeper.zuul.svc.cluster.local}
zookeeper_port=${ZUUL_STOP_ZOOKEEPER_PORT:-2281}
executor=${ZUUL_STOP_EXECUTOR:-/usr/local/bin/zuul-executor}

"$executor" -f &
pid=$!

# alive: zuul-executor has not exited (a zombie, not yet waited for, has).
alive() { [ -r "/proc/$pid/stat" ] && ! grep -q '^[0-9]* (.*) Z ' "/proc/$pid/stat"; }
# zookeeper_answers: a TCP connection to ZooKeeper's port opens within 3 seconds.
zookeeper_answers() {
  python3 -c "import socket; socket.create_connection(('$zookeeper_host', $zookeeper_port), 3).close()" 2> /dev/null
}

stop() {
  trap '' TERM INT
  echo "run.sh: stopping zuul-executor gracefully, for at most ${deadline}s"
  kill -TERM "$pid" 2> /dev/null
  start=$(date +%s)
  missed=0
  tick=0
  while alive; do
    # ZooKeeper every 5 seconds; whether zuul-executor exited, every second.
    if [ $((tick % 5)) -eq 0 ]; then
      if zookeeper_answers; then missed=0; else missed=$((missed + 1)); fi
    fi
    tick=$((tick + 1))
    if [ "$missed" -ge 2 ]; then
      echo "run.sh: ZooKeeper does not answer, so zuul-executor cannot stop gracefully: stopping it hard"
      kill -KILL "$pid" 2> /dev/null
      break
    fi
    if [ $(( $(date +%s) - start )) -ge "$deadline" ]; then
      echo "run.sh: zuul-executor still running after ${deadline}s: stopping it hard"
      kill -KILL "$pid" 2> /dev/null
      break
    fi
    sleep 1
  done
  wait "$pid"
  status=$?
  echo "run.sh: zuul-executor exited ($status) after $(( $(date +%s) - start ))s"
  exit "$status"
}
trap stop TERM INT

# Returns when zuul-executor exits by itself, or when a signal runs stop, which exits.
wait "$pid"
status=$?
echo "run.sh: zuul-executor exited by itself ($status)"
exit "$status"
