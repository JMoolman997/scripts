#!/usr/bin/env bats

# Strip ANSI color codes so we can assert on the clean text
strip_colors() {
  sed -E 's/\x1B\[[0-9;]*m//g'
}

setup() {
  unset -f log info warn error debug custom_log color_print
  unset LOG_LEVEL

  # locate and source the library under test
  project_root="$BATS_TEST_DIRNAME/.."
  . "$project_root/lib/log.sh"

  # export the functions so child bash -c calls can see them
  export -f log info warn error debug custom_log color_print
}
@test "custom_log() is defined" {
  run bash -c 'declare -f custom_log'
  [ "$status" -eq 0 ]
}

@test "color_print() is defined" {
  run bash -c 'declare -f color_print'
  [ "$status" -eq 0 ]
}
@test "info(): emits INFO only at level ≥2" {
  run bash -c 'LOG_LEVEL=2; info "hello world" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [[ "$clean" =~ \[INFO\]\ hello\ world ]]

  run bash -c 'LOG_LEVEL=1; info "silent" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [ -z "$clean" ]
}

@test "warn(): emits WARNING only at level ≥1" {
  run bash -c 'LOG_LEVEL=1; warn "caution" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [[ "$clean" =~ \[WARNING\]\ caution ]]

  run bash -c 'LOG_LEVEL=0; warn "no output" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [ -z "$clean" ]
}

@test "debug(): emits DEBUG only at level ≥3" {
  run bash -c 'LOG_LEVEL=3; debug "details" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [[ "$clean" =~ \[DEBUG\]\ details ]]

  run bash -c 'LOG_LEVEL=2; debug "none" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [ -z "$clean" ]
}

@test "error(): emits ERROR and exits non-zero" {
  run bash -c 'LOG_LEVEL=2; error "fatal" 2>&1'
  [ "$status" -ne 0 ]
  clean="$(echo "$output" | strip_colors)"
  [[ "$clean" =~ \[ERROR\]\ fatal ]]
}

@test "timestamp follows ISO-8601 format" {
  run bash -c 'LOG_LEVEL=2; info "check time" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  ts="$(echo "$clean" | awk '{print $1}')"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]
}

@test "custom_log(): emits custom label with fg color only" {
  run bash -c 'LOG_LEVEL=2; custom_log NOTICE COLOR_MAGENTA "hey there" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [[ "$clean" =~ \[NOTICE\]\ hey\ there ]]
}

@test "custom_log(): emits custom label with fg+bg colors" {
  run bash -c 'LOG_LEVEL=2; custom_log ALERT COLOR_WHITE BG_RED "danger zone" 2>&1'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [[ "$clean" =~ \[ALERT\]\ danger\ zone ]]
}

@test "color_print(): prints text in fg color only" {
  run bash -c 'color_print COLOR_CYAN "just cyan"'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [ "$clean" = "just cyan" ]
}

@test "color_print(): prints text in fg+bg colors" {
  run bash -c 'color_print COLOR_BLACK BG_YELLOW "blk on yel"'
  [ "$status" -eq 0 ]
  clean="$(echo "$output" | strip_colors)"
  [ "$clean" = "blk on yel" ]
}

@test "color_print: prints each COLOR_* variable colour" {
  local cols=(
    COLOR_BLACK COLOR_RED COLOR_GREEN COLOR_YELLOW
    COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_WHITE
  )

  for col in "${cols[@]}"; do
    # run color_print for each var
    run bash -c "color_print $col \"$col\""
    [ "$status" -eq 0 ]

    # strip colors and assert clean output matches the var name
    clean="$(echo "$output" | strip_colors)"
    [ "$clean" = "$col" ]
  done
}

@test "palette demo (visual check)" {
  echo "→ Palette demo below (no pass/fail assertions):" >&2
  run bash -c 'print_palette >&2'
  [ "$status" -eq 0 ]
}
