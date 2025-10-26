#!/usr/bin/env bats

setup() {
  project_root="$BATS_TEST_DIRNAME/.."
  . "$project_root/lib/pkg_utils.sh"
  export -f install_with_brew install_with_apt install_with_pacman install_with_dnf

  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
  PATH="$TEST_TMP:$PATH"
  export PATH

  cat <<'STUB' >"$TEST_TMP/sudo"
#!/usr/bin/env bash
echo "sudo $*" >>"$TEST_TMP/sudo.log"
"$@"
STUB
  chmod +x "$TEST_TMP/sudo"

  cat <<'STUB' >"$TEST_TMP/brew"
#!/usr/bin/env bash
echo "brew $*" >>"$TEST_TMP/pkg.log"
exit 0
STUB
  chmod +x "$TEST_TMP/brew"

  cat <<'STUB' >"$TEST_TMP/apt"
#!/usr/bin/env bash
if [[ "$1" == "update" ]]; then
  echo "apt update" >>"$TEST_TMP/pkg.log"
  exit 0
elif [[ "$1" == "install" ]]; then
  shift
  echo "apt install $*" >>"$TEST_TMP/pkg.log"
  exit 0
fi
echo "unexpected apt args: $*" >&2
exit 1
STUB
  chmod +x "$TEST_TMP/apt"

  cat <<'STUB' >"$TEST_TMP/pacman"
#!/usr/bin/env bash
echo "pacman $*" >>"$TEST_TMP/pkg.log"
exit 0
STUB
  chmod +x "$TEST_TMP/pacman"

  cat <<'STUB' >"$TEST_TMP/dnf"
#!/usr/bin/env bash
echo "dnf $*" >>"$TEST_TMP/pkg.log"
exit 0
STUB
  chmod +x "$TEST_TMP/dnf"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "install_with_brew delegates to brew" {
  run bash -c 'install_with_brew wget'
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/pkg.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ brew\ wget ]]
}

@test "install_with_apt updates and installs packages" {
  : >"$TEST_TMP/pkg.log"
  run bash -c 'install_with_apt htop jq'
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/pkg.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ apt\ update ]]
  [[ "$output" =~ apt\ install\ -y\ htop\ jq ]]
  run cat "$TEST_TMP/sudo.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ sudo\ apt\ update ]]
}

@test "install_with_pacman installs packages non-interactively" {
  : >"$TEST_TMP/pkg.log"
  run bash -c 'install_with_pacman neovim'
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/pkg.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ pacman\ -Syu\ --noconfirm\ neovim ]]
}

@test "install_with_dnf installs packages with sudo" {
  : >"$TEST_TMP/pkg.log"
  run bash -c 'install_with_dnf git'
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/pkg.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ dnf\ install\ -y\ git ]]
}
