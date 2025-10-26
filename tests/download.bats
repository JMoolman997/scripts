#!/usr/bin/env bats

setup() {
  project_root="$BATS_TEST_DIRNAME/.."
  . "$project_root/lib/download.sh"
  export -f download_file git_clone_or_pull download_and_unzip

  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
  PATH="$TEST_TMP:$PATH"
  export PATH

  cat <<'STUB' >"$TEST_TMP/curl"
#!/usr/bin/env bash
if [[ "$1" == "-fL" && "$2" == "-o" ]]; then
  dest="$3"; url="$4"
  printf 'fetched from %s' "$url" >"$dest"
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
STUB
  chmod +x "$TEST_TMP/curl"

  cat <<'STUB' >"$TEST_TMP/git"
#!/usr/bin/env bash
log="$TEST_TMP/git.log"
case "$1" in
  clone)
    repo="$2"; dir="$3"
    mkdir -p "$dir/.git"
    printf 'clone %s %s\n' "$repo" "$dir" >>"$log"
    exit 0
    ;;
  -C)
    dir="$2"; shift 2
    if [[ "$1" == "pull" ]]; then
      shift
      printf 'pull %s %s\n' "$dir" "$*" >>"$log"
      exit 0
    fi
    ;;
esac
echo "unexpected git args: $*" >&2
exit 1
STUB
  chmod +x "$TEST_TMP/git"

  cat <<'STUB' >"$TEST_TMP/unzip"
#!/usr/bin/env bash
zipfile=""
outdir=""
while (($#)); do
  case "$1" in
    -o)
      shift
      ;;
    -d)
      outdir="$2"
      shift 2
      ;;
    *)
      zipfile="$1"
      shift
      ;;
  esac
done

mkdir -p "$outdir"
printf 'unzipped %s' "$zipfile" >"$outdir/extracted.txt"
exit 0
STUB
  chmod +x "$TEST_TMP/unzip"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "download_file saves content using curl" {
  dest="$TEST_TMP/example.txt"
  run bash -c 'download_file "https://example.com/archive" "'$dest'"'
  [ "$status" -eq 0 ]
  [ -f "$dest" ]
  run cat "$dest"
  [ "$status" -eq 0 ]
  [[ "$output" =~ fetched ]]
}

@test "git_clone_or_pull clones when target missing" {
  target="$TEST_TMP/repo"
  run bash -c 'git_clone_or_pull "git@example.com:repo.git" "'$target'"'
  [ "$status" -eq 0 ]
  [ -d "$target/.git" ]
  run cat "$TEST_TMP/git.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ clone ]]
}

@test "git_clone_or_pull pulls when target already exists" {
  target="$TEST_TMP/repo"
  mkdir -p "$target/.git"
  : >"$TEST_TMP/git.log"
  run bash -c 'git_clone_or_pull "git@example.com:repo.git" "'$target'"'
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/git.log"
  [ "$status" -eq 0 ]
  [[ "$output" =~ pull ]]
}

@test "download_and_unzip downloads and extracts archive" {
  outdir="$TEST_TMP/out"
  run bash -c 'cd "'$TEST_TMP'" && download_and_unzip "https://example.com/tool.zip" "'$outdir'"'
  [ "$status" -eq 0 ]
  [ -f "$outdir/extracted.txt" ]
  [ ! -f "$TEST_TMP/tool.zip" ]
}
