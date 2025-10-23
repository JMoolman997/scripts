#!/usr/bin/env bats

setup() {
  project_root="$BATS_TEST_DIRNAME/.."
}

@test "__sc_adapt_logging provides fallback loggers" {
  run env PROJECT_ROOT="$project_root" bash -c '
    unset -f log_info log_warn log_error log_success info warn error success
    source "$PROJECT_ROOT/lib/sync_common.sh"
    __sc_adapt_logging
    log_info "info message"
    log_warn "warn message"
    log_error "error message"
    log_success "ok message"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] info message"* ]]
  [[ "$output" == *"[WARN] warn message"* ]]
  [[ "$output" == *"[ERROR] error message"* ]]
  [[ "$output" == *"[ OK ] ok message"* ]]
}

@test "__sc_adapt_logging preserves existing log functions" {
  run env PROJECT_ROOT="$project_root" bash -c '
    log_info(){ printf "custom: %s" "$*"; }
    source "$PROJECT_ROOT/lib/sync_common.sh"
    __sc_adapt_logging
    log_info "hello"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "custom: hello" ]
}

@test "sc_has_flag detects known rsync option" {
  run env PROJECT_ROOT="$project_root" bash -c '
    source "$PROJECT_ROOT/lib/sync_common.sh"
    sc_has_flag --archive
  '

  [ "$status" -eq 0 ]
}

@test "sc_has_flag returns non-zero for unknown option" {
  run env PROJECT_ROOT="$project_root" bash -c '
    source "$PROJECT_ROOT/lib/sync_common.sh"
    sc_has_flag --definitely-not-a-real-flag
  '

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "sc_build_ssh_opts populates defaults" {
  run env PROJECT_ROOT="$project_root" HOME="$BATS_TEST_TMPDIR/home" bash -c '
    source "$PROJECT_ROOT/lib/sync_common.sh"
    sc_build_ssh_opts 2222
    [[ -d "$CM_DIR" ]]
    declare -p CM_DIR SOCK SSH_OPTS
  '

  [ "$status" -eq 0 ]

  expected_cm="$BATS_TEST_TMPDIR/home/.ssh/cm"
  expected_sock="$expected_cm/%C"
  [[ "$output" == *"CM_DIR=\"$expected_cm\""* ]]
  [[ "$output" == *"SOCK=\"$expected_sock\""* ]]
  [[ "$output" == *"[0]=\"-p\""* ]]
  [[ "$output" == *"[1]=\"2222\""* ]]
  [[ "$output" == *"Ciphers=aes128-gcm@openssh.com"* ]]
}

@test "sc_build_ssh_opts keeps existing CM_DIR and SOCK" {
  run env PROJECT_ROOT="$project_root" CM_DIR="$BATS_TEST_TMPDIR/custom_cm" SOCK="$BATS_TEST_TMPDIR/custom_sock" bash -c '
    source "$PROJECT_ROOT/lib/sync_common.sh"
    sc_build_ssh_opts 2022
    declare -p CM_DIR SOCK
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"CM_DIR=\"$BATS_TEST_TMPDIR/custom_cm\""* ]]
  [[ "$output" == *"SOCK=\"$BATS_TEST_TMPDIR/custom_sock\""* ]]
}
