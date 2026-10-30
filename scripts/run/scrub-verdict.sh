# shellcheck shell=bash
# ============================================================
# scrub-verdict.sh - the scrub probe and how to read what it printed.
#
# Sourced by check-scrub-local.sh and check-scrub-fargate.sh; not run on its own. Both send the same
# probe and classify the answers the same way, so a result from a Docker host and one from a Fargate
# task can be compared line for line.
#
# Expects the caller to have set TMP, a directory holding LABEL.out (the run's output, already
# redacted) and LABEL.rc (its exit code) for every run it classifies.
# Bash 3.2 compatible (macOS).
# ============================================================

# The probe. The markers are built at run time ("plain-%s", "key-$s", "...: $n"), so an agent that
# quotes a command in its answer cannot match them by accident. Commands 1-3 use no ${}, loop or
# command substitution; 4 and 5 are the forms first-runs.sh uses.
scrub_probe_prompt() { # prints the probe as one line
    local p
    IFS= read -r -d '' p <<'EOF' || true
Run these five shell commands, one at a time, and report each output, nothing else. The commands are the text between backticks.
1) `printf 'plain-%s\n' ok`
2) `printenv ANTHROPIC_API_KEY >/dev/null && printf 'plain-key=%s\n' VISIBLE || printf 'plain-key=%s\n' hidden`
3) `grep -la ANTHROPIC_API_KEY /proc/[0-9]*/environ 2>/dev/null | wc -l | sed 's/^/plain-proc=/'`
4) `if [ -n "${ANTHROPIC_API_KEY:-}" ]; then s=VISIBLE; else s=hidden; fi; echo "key-$s"`
5) `n=0; for f in /proc/[0-9]*/environ; do grep -qa ANTHROPIC_API_KEY "$f" 2>/dev/null && n=$((n+1)); done; echo "proc-environ-with-key: $n"`
If a command is blocked or prints an error, report the message exactly and go on with the next one. Never print the value of any variable.
EOF
    p="${p//$'\n'/ }"
    printf '%s' "${p% }"
}

# What a run showed. KEYVIS (yes/no/n/a) and PROCN (a number or n/a) come from the plain commands,
# or from the ${}/loop commands where the plain ones gave no answer. PLAIN: a plain command ran.
# FORMS: how the two ${}/loop commands fared (ran, only one ran, refused, gave no output); set only
# when a plain command ran. NOTE: why nothing ran, or why the key check gave no answer.
classify() {
    local f="$TMP/$1.out" p_key="n/a" p_proc c_key="n/a" c_proc seen=0
    KEYVIS="n/a" PROCN="n/a" PLAIN="no" FORMS="n/a" NOTE="" REASON=""
    if grep -q 'plain-key=VISIBLE' "$f"; then p_key=yes; elif grep -q 'plain-key=hidden' "$f"; then p_key=no; fi
    p_proc="$(sed -n 's/.*plain-proc=\([0-9][0-9]*\).*/\1/p' "$f" | head -n 1)"
    [ -n "$p_proc" ] || p_proc="n/a"
    if grep -q 'key-VISIBLE' "$f"; then c_key=yes; elif grep -q 'key-hidden' "$f"; then c_key=no; fi
    c_proc="$(sed -n 's/.*proc-environ-with-key: \([0-9][0-9]*\).*/\1/p' "$f" | head -n 1)"
    [ -n "$c_proc" ] || c_proc="n/a"
    if grep -q 'plain-ok' "$f" || [ "$p_key" != "n/a" ] || [ "$p_proc" != "n/a" ]; then PLAIN=yes; fi
    KEYVIS="$p_key"; [ "$KEYVIS" != "n/a" ] || KEYVIS="$c_key"
    PROCN="$p_proc"; [ "$PROCN" != "n/a" ] || PROCN="$c_proc"
    [ "$c_key" = "n/a" ] || seen=$((seen + 1))
    [ "$c_proc" = "n/a" ] || seen=$((seen + 1))
    if [ "$PLAIN" = "yes" ]; then
        if [ "$seen" = 2 ]; then FORMS="ran"
        elif [ "$seen" = 1 ]; then FORMS="only one ran"
        elif grep -qi 'requires approval\|blocked\|can.t be checked' "$f"; then FORMS="refused"
        else FORMS="gave no output"; fi
    fi
    if [ "$KEYVIS" = "n/a" ]; then
        if [ "$PLAIN" = "yes" ]; then
            NOTE="a plain command ran, but the key check gave no answer"
        elif grep -qi 'No permissions to create new namespace' "$f"; then
            NOTE="bubblewrap could not create a namespace"
        elif grep -qi 'bwrap:' "$f"; then
            NOTE="bubblewrap failed"
        elif grep -qi 'Sandbox is required\|requires approval\|blocked\|can.t be checked' "$f"; then
            NOTE="every command was blocked, even a trivial one"
        else
            NOTE="no marker in the output (see the log)"
        fi
        # The agent's words for why: the first line that says so, from "bwrap:" on if it has one, without list
        # numbers, backticks or the agent's own markdown around the message; cut at 240 characters.
        REASON="$(grep -m1 -i 'Sandbox is required\|bwrap:\|requires approval\|can.t be checked' "$f")" || REASON=""
        case "$REASON" in *bwrap:*) REASON="bwrap:${REASON#*bwrap:}" ;; esac
        # shellcheck disable=SC2016  # the backticks are characters for sed to strip, not a command substitution
        REASON="$(printf '%s' "$REASON" \
            | sed 's/^[[:space:]]*[0-9]*[.)]*[[:space:]]*//; s/^[`[:space:]]*//; s/[`[:space:]]*$//; s/`\.$//' | cut -c1-240)"
    fi
}
works() { [ "$KEYVIS" = "no" ] && [ "$PROCN" = "0" ]; } # the key is hidden and no /proc/*/environ holds it
state() { # the class of the run just classified: works, visible (key still seen), partly (plain commands ran only) or blocked
    if works; then echo works
    elif [ "$KEYVIS" != "n/a" ]; then echo visible
    elif [ "$PLAIN" = "yes" ]; then echo partly
    else echo blocked; fi
}
forms_failed() { [ "$1" = "refused" ] || [ "$1" = "gave no output" ]; } # a FORMS value

verdict_line() { # verdict_line LABEL TEXT -> "A  scrub on, default flags: ..."
    classify "$1"
    local what
    case "$(state)" in
        works) what="WORKS: the key is hidden from a command and 0 /proc/*/environ files hold it" ;;
        visible) what="DOES NOT HOLD: key in a command's environment: $KEYVIS, /proc/*/environ files with the key: $PROCN" ;;
        partly) what="PARTLY RAN: $NOTE" ;;
        *) what="COULD NOT RUN: $NOTE" ;;
    esac
    [ -z "$REASON" ] || what="$what; the agent reported: \"$REASON\""
    [ "$PLAIN" != "yes" ] || what="$what; the commands with \${} and a loop: $FORMS"
    printf '%s  %s: %s (exit %s)\n' "$1" "$2" "$what" "$(cat "$TMP/$1.rc")"
}
