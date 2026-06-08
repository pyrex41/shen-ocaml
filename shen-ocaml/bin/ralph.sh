#!/bin/bash
# Ralph loop: four-gate backpressure with cursor-agent as the inner harness.
#
# Each iteration:
#   1. Call cursor-agent with the prompt (plan + any backpressure errors)
#   2. Gate 1: shengen — regenerate guard types from specs
#   3. Gate 2: build  — nix develop + dune build
#   4. Gate 3: test   — nix develop + dune test
#   5. Gate 4: shen-check — verify specs with tc+
#   If any gate fails, the error becomes backpressure for the next iteration.
#
# Environment:
#   RALPH_MAX_ITER    — max iterations (default 20)
#   RALPH_MODEL       — model ID (default cursor-2)
#   RALPH_TIMEOUT     — per-call timeout in seconds (default 600)
#   RALPH_PLAN        — path to plan file (default plans/implementation_plan.md)
#   RALPH_SLEEP       — seconds between iterations (default 5)
#   RALPH_HARNESS     — harness command (default: cursor-agent)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

MAX_ITER="${RALPH_MAX_ITER:-10}"
MODEL="${RALPH_MODEL:-composer-2}"
TIMEOUT="${RALPH_TIMEOUT:-900}"
PLAN="${RALPH_PLAN:-plans/implementation_plan.md}"
SLEEP="${RALPH_SLEEP:-5}"
HARNESS="${RALPH_HARNESS:-cursor-agent}"
LOG="plans/backpressure.log"

mkdir -p plans

# ---- cleanup on exit ----
cleanup() {
  pkill -f "main\.exe" 2>/dev/null || true
  pkill -f "test_kernel" 2>/dev/null || true
  pkill -f "cursor-agent" 2>/dev/null || true
  pkill -f "dune test" 2>/dev/null || true
  pkill -f "dune build" 2>/dev/null || true
  rm -f "$PROJECT_DIR/_build/.lock" 2>/dev/null || true
}
trap cleanup EXIT

# ---- helpers ----

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "[$(timestamp)] $*" | tee -a "$LOG"; }

run_gate() {
  local gate_name="$1"; shift
  log "GATE: $gate_name"
  local output
  if output=$("$@" 2>&1); then
    log "GATE $gate_name: PASS"
    return 0
  else
    log "GATE $gate_name: FAIL"
    echo "$output" >> "$LOG"
    BACKPRESSURE+="

## Gate failure: $gate_name
\`\`\`
$output
\`\`\`
"
    return 1
  fi
}

# ---- main loop ----

if [ ! -f "$PLAN" ]; then
  log "ERROR: plan file not found: $PLAN"
  log "Create it first, or set RALPH_PLAN= to point to an existing plan."
  exit 1
fi

BACKPRESSURE=""
ITER=0

log "Ralph loop starting: harness=$HARNESS model=$MODEL max_iter=$MAX_ITER plan=$PLAN"

while [ "$ITER" -lt "$MAX_ITER" ]; do
  ITER=$((ITER + 1))
  log "=== Iteration $ITER / $MAX_ITER ==="

  # Build the prompt for this iteration — keep it short, tell agent to read the plan file
  PROMPT="You are working on shen-ocaml. Iteration $ITER / $MAX_ITER.
Project root: $PROJECT_DIR

Read the plan: $PROJECT_DIR/$PLAN

Four gates run automatically after you: shengen, build (dune build), test (dune test), shen-check.
Pick up the FIRST unchecked task (marked [ ]) in the plan. Do ONE sub-task per iteration.
Do NOT skip ahead. Do NOT mark tasks done until they actually work.
Do NOT add demo/hardcoded/fake responses — everything must work for real.
Work inside nix develop (OCaml 5.3.0, dune 3.20.2)."

  if [ -n "$BACKPRESSURE" ]; then
    PROMPT+="

## Backpressure from previous iteration
$BACKPRESSURE"
  fi

  # Call the inner harness
  log "Calling $HARNESS (model=$MODEL)"
  timeout --signal=KILL "$TIMEOUT" "$HARNESS" \
    -p \
    --model "$MODEL" \
    --workspace "$PROJECT_DIR" \
    --force \
    --trust \
    "$PROMPT" \
    2>&1 | tee -a "$LOG" || {
      log "WARNING: $HARNESS exited non-zero or timed out"
    }

  # Kill any orphaned processes from this iteration (dune lock contention!)
  pkill -f "main\.exe" 2>/dev/null || true
  pkill -f "test_kernel" 2>/dev/null || true
  pkill -f "dune test" 2>/dev/null || true
  pkill -f "dune build" 2>/dev/null || true
  sleep 1
  rm -f "$PROJECT_DIR/_build/.lock"  # clear stale dune lock
  sleep 1

  # Reset backpressure for this iteration
  BACKPRESSURE=""
  GATE_FAILED=0

  # Gate 1: shengen
  run_gate "shengen" bash bin/shengen-codegen.sh || GATE_FAILED=1

  # Gate 2: build
  run_gate "build" nix develop --command bash -c "dune build" || GATE_FAILED=1

  # Gate 3: test
  run_gate "test" nix develop --command bash -c "dune test" || GATE_FAILED=1

  # Gate 4: shen-check
  run_gate "shen-check" bash bin/shen-check.sh || GATE_FAILED=1

  if [ "$GATE_FAILED" -eq 0 ]; then
    log "All gates passed."
  else
    log "Gate failures detected — backpressure will be sent to next iteration."
  fi

  if [ "$ITER" -lt "$MAX_ITER" ]; then
    sleep "$SLEEP"
  fi
done

log "Ralph loop complete after $ITER iterations."
