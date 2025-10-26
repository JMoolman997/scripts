#!/usr/bin/env bats

setup() {
  project_root="$BATS_TEST_DIRNAME/.."
  . "$project_root/lib/system_info.sh"
  export -f detect_os get_cpu_info get_total_ram get_disk_info get_free_disk
  export -f get_current_user get_current_dir get_path get_env_var

  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
  PATH="$TEST_TMP:$PATH"
  export PATH

  cat <<'STUB' >"$TEST_TMP/nproc"
#!/usr/bin/env bash
echo 8
STUB
  chmod +x "$TEST_TMP/nproc"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "detect_os honors explicit override" {
  run bash -c 'SC_SYSTEM_INFO_OS=arch detect_os'
  [ "$status" -eq 0 ]
  [ "$output" = "arch" ]
}

@test "detect_os infers distro from root override" {
  root="$TEST_TMP/fake_root"
  mkdir -p "$root/etc"
  touch "$root/etc/debian_version"
  run bash -c 'SC_SYSTEM_INFO_ROOT="'$root'" detect_os'
  [ "$status" -eq 0 ]
  [ "$output" = "debian" ]
}

@test "get_cpu_info reports model and cores" {
  root="$TEST_TMP/fake_root"
  mkdir -p "$root/proc"
  printf 'processor\t: 0\nmodel name\t: Test CPU 3000\nprocessor\t: 1\nmodel name\t: Test CPU 3000\n' >"$root/proc/cpuinfo"
  run bash -c 'SC_SYSTEM_INFO_ROOT="'$root'" detect_os >/dev/null; SC_SYSTEM_INFO_ROOT="'$root'" get_cpu_info'
  [ "$status" -eq 0 ]
  [[ "$output" =~ Model:\ Test\ CPU\ 3000 ]]
  [[ "$output" =~ Cores:\ 8 ]]
}

@test "get_total_ram reads from /proc/meminfo" {
  root="$TEST_TMP/fake_root"
  mkdir -p "$root/proc"
  cat <<'MEM' >"$root/proc/meminfo"
MemTotal:       1048576 kB
MEM
  run bash -c 'SC_SYSTEM_INFO_ROOT="'$root'" detect_os >/dev/null; SC_SYSTEM_INFO_ROOT="'$root'" get_total_ram'
  [ "$status" -eq 0 ]
  [ "$output" = "1024 MB" ]
}

@test "disk helpers emit expected keywords" {
  run bash -c 'get_disk_info'
  [ "$status" -eq 0 ]
  [[ "$output" =~ Used: ]]

  run bash -c 'get_free_disk'
  [ "$status" -eq 0 ]
  [[ "$output" =~ free ]]
}

@test "environment helpers expose current values" {
  run bash -c 'get_current_user'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  run bash -c 'get_current_dir'
  [ "$status" -eq 0 ]
  [[ "$output" = "$PWD" ]]

  run bash -c 'get_path'
  [ "$status" -eq 0 ]
  [[ "$output" = "$PATH" ]]

  run bash -c 'FOO=bar get_env_var FOO'
  [ "$status" -eq 0 ]
  [ "$output" = "bar" ]

  run bash -c 'unset FOO; get_env_var FOO'
  [ "$status" -eq 0 ]
  [ "$output" = "unset" ]
}
