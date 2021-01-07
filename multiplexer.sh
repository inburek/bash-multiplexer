#!/usr/bin/env bash
# Bash Multiplexer Version 0.9
set -eu -o pipefail

# HELP FUNCTION

SCRIPT_USAGE_INSTRUCTIONS=$(cat <<USAGE
Arguments:
                      ╭──────────────────── [0-9]+|auto ┆ 1. How much width to use in total.
                      │                                 ┆    'auto' means that the width will
                      │                                 ┆    be automatically detected.
                      │   ╭──────────────── [0-9]+|auto ┆ 2. How much width to give to each process
                      │   │                             ┆    before moving on to the next process.
                      │   │                             ┆    'auto' means that there will be no overlap.
                      │   │  ╭───────────── [0-9]+      ┆ 3. How many lines to read at a time,
                      │   │  │                          ┆    purely for readability.
    ./multiplexer.sh 150 80 10 < command-list.txt
                               ╰───────────────────────── stdin should have a command on each line
Usage example:
./multiplexer.sh auto auto 10 <<'EOF'
test_command  0  800 color 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
test_command  0 3000 plain 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
test_command  0  600 color 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
test_command 11 3000 color 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
EOF
USAGE
)

# ARGUMENTS

SCRIPT_WIDTH_AVAILABLE="${1?"Please provide argument 1. $SCRIPT_USAGE_INSTRUCTIONS"}"
SCRIPT_COLUMN_WIDTH="${2?"Please provide argument 2. $SCRIPT_USAGE_INSTRUCTIONS"}"
SCRIPT_MAX_LINES_FOR_SAME_PROCESS="${3?"Please provide argument 3. $SCRIPT_USAGE_INSTRUCTIONS"}"

if [[ "$SCRIPT_WIDTH_AVAILABLE" == 'auto' ]]; then
  SCRIPT_WIDTH_AVAILABLE="$(tput cols)"
fi

# STANDARD INPUT

__SCRIPT_COMMAND=()
while read -r __current_command; do
  __SCRIPT_COMMAND+=("$__current_command")
done

if [[ "$SCRIPT_COLUMN_WIDTH" == 'auto' ]]; then
  SCRIPT_COLUMN_WIDTH=$(($SCRIPT_WIDTH_AVAILABLE / ${#__SCRIPT_COMMAND[@]}))
fi

# CONSTANTS
DEBUGGING_COLORS="${DEBUGGING_COLORS:-0}"

FMT_RST='[0m'
FMT_AZURE='[36m'
FMT_PATTERN='\[([0-9]+)(;[0-9]*)*m'
FMT_ANY_RST_NUMBER_PATTERN='0||2[0-9]|39|49'
FMT_ANY_RST_PATTERN="\[($FMT_ANY_RST_NUMBER_PATTERN)m"

# GENERAL DEBUGGING UTILITIES

function args_debug () {
  >&2 echo "$1:"
  local arg; for arg in "${@:2}"; do
    >&2 echo " ${arg@Q}"
  done
}
args_debug "COMMANDS" "${__SCRIPT_COMMAND[@]}"

if (( ${#__SCRIPT_COMMAND[@]} <= 1 )); then
  SCRIPT_INDENTATION_COLS=0
else
  SCRIPT_INDENTATION_COLS=$(( ($SCRIPT_WIDTH_AVAILABLE - $SCRIPT_COLUMN_WIDTH) / (${#__SCRIPT_COMMAND[@]} - 1) ))
fi
SCRIPT_INDENTATION="$(printf "%${SCRIPT_INDENTATION_COLS}s")"

function consumer_stderr () {
  cat | sed -E 's:^:E :g'
}
function consumer_stdout () {
  cat | sed -E 's:^:O :g'
}

function sed_apply_forever () {
  local SUBSTITUTIONS=("$@")
  local STRING="$(cat)"
  local OLD_STRING=" $STRING"
  local MAX_ITERATIONS=10
  local ITERATIONS=0
  while [[ "$STRING" != "$OLD_STRING" ]]; do
    if (($MAX_ITERATIONS <= $ITERATIONS)); then
      break;
    fi
    OLD_STRING="$STRING"
    local substitution; for substitution in "${SUBSTITUTIONS[@]}"; do
      STRING="$(sed -E "$substitution" <<< "$STRING")"
    done
    ITERATIONS=$((ITERATIONS + 1))
  done
  printf "%s" "$STRING"
}

function fmt_1_extract () {
  local TR_EXIT_STATUS
  (grep -oh -E "$FMT_PATTERN" || true) | tr -d '\n' || { TR_EXIT_STATUS=$?; $(($TR_EXIT_STATUS == 130 )) || >&2 echo "Failed in fmt_1_extract! Exit code: $?. PIPESTATUS:" "${PIPESTATUS[@]}"; }
}

function fmt_2_simplify () {
  local ESCAPES="$(cat)"
  if [[ "$ESCAPES" == '' ]]; then
    return 0
  else
    cat <<< "$ESCAPES" |
    # Leaves: 55;33 0 23;6 7 38;5;190
    sed -E 's#(\[|m)+# #g' |
    # A semicolon at the edge or two consecutive semicolons mean that a number was absent, which behaves like a 0
    sed -E 's#([ ;])([ ;])#\10\2#g' |
    # Split out foreground and background composites as their own thing and mark with : instead of ;
    sed -E 's#;?\b(38|48);(5);([0-9]+)\b;?# \1:\2:\3 #g' |
    # Turn ; into spaces
    sed -E 's#;# #g' |
    # Turn : back into ;
    sed -E 's#:#;#g' |
    # Remove unnecessary spaces
    sed -E 's# +# #g' |
    sed -E 's#^ | $##g' |
    sed -E 's# *\b([^ ]+)\b *#<\1>#g' |
    cat
  fi
}

function fmt_3_collapse () {
  local ESCAPES="$(cat)"
  if [[ "$ESCAPES" == '' ]]; then
    return 0
  else
    cat <<< "$ESCAPES" \
    | sed_apply_forever \
        's/.*(<0*>)/\1/g' \
    | sed_apply_forever \
        's/(<(3|9)[0-9]\b[^<>]*>)(.*)(<(3|9)[0-9]\b[^<>]*>)/\3\4/g' \
        's/(<(4|10)[0-9]\b[^<>]*>)(.*)(<(4|10)[0-9]\b[^<>]*>)/\3\4/g' \
        's/<([1-9])>(.*)(<2\1>)/\2\3/g' \
    | sed_apply_forever 's/(<[^<>]+>)(.*)(\1)/\2\3/g' \
    | sed_apply_forever "s/(^|<0*>)(.*)(<($FMT_ANY_RST_NUMBER_PATTERN)>)/\1\2/g" \
    | cat
  fi
}

fmt_assume_no_previous_fmt () {
  local ESCAPES="$(cat)"
  if [[ "$ESCAPES" == '' ]]; then
    return 0
  else
    sed -E "s/^(<($FMT_ANY_RST_NUMBER_PATTERN)>)+//g" <<< "$ESCAPES"
  fi
}

fmt_make_resets () {
  [[ "$(fmt_2_simplify | fmt_3_collapse | fmt_assume_no_previous_fmt)" != '' ]] && echo '<0>'
}

function fmt_4_reconstruct () {
  sed -E 's:<([^<>]+)>:[\1m:g'
}

function fmt_random () {
  case "$(($RANDOM % 35))" in
    1) [[ $(($RANDOM % 2)) == 0 ]] && printf '[%sm' 1 || printf '[%sm' 21 ;;
    4) [[ $(($RANDOM % 2)) == 0 ]] && printf '[%sm' 4 || printf '[%sm' 24 ;;
    5) [[ $(($RANDOM % 2)) == 0 ]] && printf '[%sm' 5 || printf '[%sm' 25 ;;
    7) [[ $(($RANDOM % 2)) == 0 ]] && printf '[%sm' 7 || printf '[%sm' 27 ;;
    8) [[ $(($RANDOM % 2)) == 0 ]] && printf '[%sm' 8 || printf '[%sm' 28 ;;
    9) printf '[%sm' 39 ;;
    10|11|12) printf '[%sm' 49 ;;
    13|14|15) printf '[38;5;%sm' $(($RANDOM % 256)) ;;
    16|17|18)
      local OPTIONS=(30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97)
      printf '[%sm' "${OPTIONS[$RANDOM % ${#OPTIONS[@]} ]}"
      ;;
    19|20|21)
      local OPTIONS=(40 41 42 43 44 45 46 47 100 101 102 103 104 105 106 107)
      printf '[%sm' "${OPTIONS[$RANDOM % ${#OPTIONS[@]} ]}"
      ;;
    25|26) printf '[%sm' 0 ;;
    27) printf '[%sm' '' ;;
    *)
      sed -E 's:m\[:;:g' <<< "$(fmt_random; fmt_random)" | tr -d '\n'
      ;;
  esac
}

function test_command () {
  local EXIT_STATUS="$1"
  local MAX_CHARACTERS="$2"
  local COLORS="$3"
  local STRING="$4"
  local COUNT=1
  echo "████████ Executing: test_command █████████"

  local CHARACTERS_SO_FAR=0
  while true; do
    local SLEEP="$(($RANDOM % 3))"
    local ITERATIONS="$(($RANDOM % 10 * 50))"
    local i; for ((i=0; i < ${ITERATIONS}; i++)); do
      if [[ "$COLORS" == 'plain' ]]; then
        local ESCAPE='';
      else
        local ESCAPE="$([[ $(($RANDOM % 40)) == 0 ]] && fmt_random || echo '')"
      fi

      local COUNT_STR="$(printf "%- 3s" "$COUNT")"
      local MAYBE_NEWLINE="$([[ "$(($RANDOM % 20))" == 0 ]] && echo $'█\n█' || echo '')"
      if [[ "$(($RANDOM % 2))" == 0 ]]; then
        >&2 printf "%s%s%s" "$ESCAPE" "$STRING" "$MAYBE_NEWLINE"
      else
        printf "%s%s%s" "$ESCAPE" "$STRING" "$MAYBE_NEWLINE"
      fi
      CHARACTERS_SO_FAR=$(($CHARACTERS_SO_FAR + ${#STRING}));
      COUNT=$((COUNT + 1))
      if (( $CHARACTERS_SO_FAR >= $MAX_CHARACTERS )); then
        break 2
      fi
    done
    sleep "$SLEEP";
  done
  echo -e '\n████████████████████████████████'
  echo -e "Done after $SECONDS seconds"
  sleep 1
  return "$EXIT_STATUS"
}

function print_indented_and_squeezed () {
  INITIAL_ESCAPES="$1"
  MAX_WIDTH="$2"
  INDENTATION="$3"
  local INPUT="$(cat)"

  local ACCUMULATED_FMT_CODES="$INITIAL_ESCAPES"
  if [[ "$ACCUMULATED_FMT_CODES" != '' ]] && grep -E "$FMT_ANY_RST_PATTERN" <<< "$ACCUMULATED_FMT_CODES" > /dev/null || ((${#ACCUMULATED_FMT_CODES} >= 60 )); then
    ACCUMULATED_FMT_CODES="$(fmt_2_simplify <<< "$ACCUMULATED_FMT_CODES" | fmt_3_collapse | fmt_assume_no_previous_fmt | fmt_4_reconstruct)"
  fi

  local LINES=0

  if [[ "$INPUT" == '' ]]; then
    LINES=1
    echo "$INDENTATION"
  else
    local ORIGINAL_LINE;
    while read -r ORIGINAL_LINE; do
      local ORIGINAL_LINE_SPLIT="$(grep -oh --color=never -E "((($FMT_PATTERN)+.?|.){0,$MAX_WIDTH})" <<< "$ORIGINAL_LINE")"
      local LINE='';
      while read -r LINE; do
        local OLD_ACCUMULATED_FMT_CODES="$ACCUMULATED_FMT_CODES"

        ACCUMULATED_FMT_CODES="$ACCUMULATED_FMT_CODES$(fmt_1_extract <<< "$LINE")"
        if [[ "$ACCUMULATED_FMT_CODES" != '' ]]; then
          LINE="$LINE$FMT_RST"
        fi
        LINE="$OLD_ACCUMULATED_FMT_CODES$LINE"
        (( LINES = $LINES + 1 ))
        echo "$INDENTATION$LINE"
        if (( $DEBUGGING_COLORS )); then
          echo "$INDENTATION$OLD_ACCUMULATED_FMT_CODES${LINE@Q}$FMT_RST"
        fi
      done <<< "$(echo "$ORIGINAL_LINE_SPLIT")"
    done <<< "$INPUT"
  fi

  export RESULT_ACCUMULATED_FMT="$ACCUMULATED_FMT_CODES"
  export RESULT_LINES_WRITTEN="$LINES"
}

function command_monitor () {
  local FULL_DESCRIPTORS=()
  local DESCRIPTORS=()
  local INDENTATIONS=()
  local ESCAPES=()
  local INDENTATION=''
  local fifo; for fifo in "$@"; do
    FULL_DESCRIPTORS+=("$fifo")
    DESCRIPTORS+=("$(sed -E 's:^/dev/fd/::' <<< "$fifo")")
    ESCAPES+=('')
    INDENTATIONS+=("$INDENTATION")
    INDENTATION="$INDENTATION$SCRIPT_INDENTATION"
  done

  local DESCRIPTORS_LEFT="${#DESCRIPTORS[@]}"

  while (( $DESCRIPTORS_LEFT > 0 )); do
    local di; for ((di=0; di < ${#DESCRIPTORS[@]}; di++)); do
      local descriptor="${DESCRIPTORS[$di]}"
      if [[ "$descriptor" != '' ]]; then
        local LINE;
        local CURRENT_ESCAPES="${ESCAPES[$di]}"
        local LINES_COLLECTED=0
        while true; do
          local READ_EXIT_CODE=0
          IFS= read -r -n 5000 "-u$descriptor" '-t0.2' LINE || READ_EXIT_CODE="$?"
          if [[ "$READ_EXIT_CODE" == 0 ]]; then
            if [[ "${LINE+x}" != "x" ]]; then
              break # LINE not defined.
            fi

            print_indented_and_squeezed \
              "$CURRENT_ESCAPES" \
              "$SCRIPT_COLUMN_WIDTH" \
              "${INDENTATIONS[$di]}" \
              <<< "$LINE"

            CURRENT_ESCAPES="$RESULT_ACCUMULATED_FMT"
            LINES_COLLECTED=$(($LINES_COLLECTED + $RESULT_LINES_WRITTEN))
          elif (( $READ_EXIT_CODE > 128 )); then # timeout
            break
          else
            DESCRIPTORS_LEFT=$(($DESCRIPTORS_LEFT - 1))
            DESCRIPTORS[$di]=''
            break
          fi
          if (($LINES_COLLECTED >= $SCRIPT_MAX_LINES_FOR_SAME_PROCESS)); then
            break
          fi
        done
        if [[ "$CURRENT_ESCAPES" != '' ]]; then
          ESCAPES[$di]="$(fmt_2_simplify <<< "$CURRENT_ESCAPES" | fmt_3_collapse | fmt_assume_no_previous_fmt | fmt_4_reconstruct)"
        else
          ESCAPES[$di]="$CURRENT_ESCAPES"
        fi
      fi
    done
  done
}

TEMP_DIR="/tmp/multiplexer-exit-codes"
EXIT_CODES_FILE="$TEMP_DIR/$(date +'%Y%m%d-%H%M%S.%N')"
mkdir -p "$TEMP_DIR"
true > "$EXIT_CODES_FILE"
function append_exit_codes () {
  local COMMAND_DESCRIPTION="$1"
  local EXIT_CODE="$2"
  local COMMAND="$3"
  echo "Exit code for $(printf '%-12s' "$COMMAND_DESCRIPTION") = $(printf '%3s' "$EXIT_CODE")  # $COMMAND" >> "$EXIT_CODES_FILE"
}
function print_exit_codes () {
  sleep 1
  echo
  echo "Multi-script ran for $SECONDS seconds."
  echo "The exit codes of the different commands were:"
  cat "$EXIT_CODES_FILE" | sort
}

FAILED=0
MONITOR_COMMAND='command_monitor '
for ((i=0; i < ${#__SCRIPT_COMMAND[@]}; i++)); do
  __script_run="${__SCRIPT_COMMAND[$i]}"

  COMMAND_INDEX="$(($i + 1))/${#__SCRIPT_COMMAND[@]}"

  STMT_TITLE_UNDERLINE="printf '% $((SCRIPT_COLUMN_WIDTH))s\n' | sed 's: :═:g'"
  STMT_EXECUTING_NOW="printf $'[92mExecuting command %s:\n  [36m%s[0m\n' ${COMMAND_INDEX@Q} ${__script_run@Q}; $STMT_TITLE_UNDERLINE"
  STMT_EVAL_AND_SET_STATUSES="(eval -- ${__script_run@Q} 2>&1) && EXIT_STATUS=\"\$?\" || EXIT_STATUS=\"\$?\""
  STMT_APPEND_EXIT_CODES="append_exit_codes 'command' ${COMMAND_INDEX@Q} \"\$EXIT_STATUS\" ${__script_run@Q}"

  STMT_SET_EXIT_COLOR='if [[ "$EXIT_STATUS" == 0 ]]; then SUCCESS_COLOR="[32m"; else SUCCESS_COLOR="[31m"; fi'
  STMT_CONCLUSION_DESCRIPTION="$STMT_SET_EXIT_COLOR; printf '[0m\n%s' \"\${SUCCESS_COLOR}\"; $STMT_TITLE_UNDERLINE; printf 'Command %s exited with status code %s after %s seconds.\n' ${COMMAND_INDEX@Q} \"\${EXIT_STATUS}\" \"\$SECONDS\""

  STMT_SUBCOMMAND="$STMT_EXECUTING_NOW; $STMT_EVAL_AND_SET_STATUSES; $STMT_CONCLUSION_DESCRIPTION; $STMT_APPEND_EXIT_CODES; sleep 2"

  EXIT_CODES_FILE+=('')
  MONITOR_COMMAND="$MONITOR_COMMAND <($STMT_SUBCOMMAND;)"
done

echo "Look for the exit codes in $EXIT_CODES_FILE"

MONITOR_EXIT_STATUS='??'
trap "echo \"Interrupted.\"; print_exit_codes; exit \$FAILED" INT
eval "$MONITOR_COMMAND" && MONITOR_EXIT_STATUS="$?" || MONITOR_EXIT_STATUS="$?";
append_exit_codes 'monitor' "$MONITOR_EXIT_STATUS" "(internal command)"

print_exit_codes
