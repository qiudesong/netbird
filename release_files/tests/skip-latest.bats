#!/usr/bin/env bats
#
# Tests for release policy, upstream mirroring and the shared installer.
# The original SKIP_LATEST cases also cover the official release channel.
#
# Run with:  bats release_files/tests/

# The sh -c scripts below take their paths as $1 and $2 rather than having
# them spliced in, where an apostrophe in a path would break the quoting.
# shellcheck disable=SC2016 # so $1 in single quotes is meant for sh

setup() {
  # First, before anything can fail: teardown removes $tmp, and a tmp
  # exported by the caller must never be what it finds there.
  tmp=''
  SCRIPT="${BATS_TEST_DIRNAME}/../skip-latest.sh"

  # Some tests build a repository of their own. Git honours GIT_DIR and its
  # kin over the current directory, and sets them for hooks, so a run from a
  # hook would commit and tag in the caller's repository instead -- and still
  # pass, reading back what it wrote. Clear every variable that ties git to a
  # repository; git lists them itself.
  # shellcheck disable=SC2046 # one name per word is the point
  unset $(git rev-parse --local-env-vars)
  # Neutralise the developer's git config too: a global tag.gpgSign turns
  # `git tag <name>` into an annotated tag and fails for want of a message.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

  # A tag set with a newer line released and an older one still maintained.
  TAGS='v0.79.0
v0.80.0-rc.1
v0.80.0
v0.80.1
v0.81.0-rc.1
v0.81.0-rc.2
v0.81.0'
}

teardown() {
  if [[ -n "${tmp:-}" ]]; then rm -rf "$tmp"; fi
}

# decide <tag> [tags]  -- tags default to $TAGS
decide() {
  local tag=$1
  local tags=${2-$TAGS}
  SKIP_LATEST_TAGS="$tags" run "$SCRIPT" "$tag"
}

# make_repo <tag>...  -- a repository of the test's own at $repo, holding the
# given tags; teardown removes it.
make_repo() {
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  mkdir -p "$repo"
  # No `|| ...` after this subshell: it would switch off bats' set -e inside,
  # and a failed cd or git init would let the commit and tags land in
  # whatever repository encloses the current directory.
  (
    cd "$repo" || exit
    # An empty --template copies no hooks into the repository, whatever
    # GIT_TEMPLATE_DIR the caller has; init.templateDir is already off.
    git init -q --template= .
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
    for tag in "$@"; do git tag "$tag"; done
  )
}

@test "the newest release moves latest" {
  decide v0.81.0
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "false" ]
}

@test "a patch on the newest line moves latest" {
  decide v0.81.1 "$TAGS
v0.81.1"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "false" ]
}

@test "a patch on an older line does not drag latest backwards" {
  decide v0.80.2 "$TAGS
v0.80.2"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "true" ]
}

@test "a release candidate never moves latest" {
  decide v0.82.0-rc.1 "$TAGS
v0.82.0-rc.1"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "true" ]
}

@test "a release is not held back by its own release candidate" {
  # sort -V orders 0.81.0-rc.1 after 0.81.0.
  decide v0.81.0 'v0.81.0-rc.1
v0.81.0'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "false" ]
}

@test "canary and hotfix tags cannot skew the comparison" {
  decide v0.81.0 "$TAGS
v0.99.0-canary.pr-1234.1
v0.99.0-hotfix-1"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "false" ]
}

@test "a new minor moves latest" {
  decide v0.82.0 "$TAGS
v0.82.0"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "false" ]
}

@test "version ordering is numeric, not lexicographic" {
  decide v0.9.0 'v0.9.0
v0.10.0'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "true" ]
}

@test "double-digit patch sorts above single-digit" {
  decide v0.81.10 'v0.81.9
v0.81.10'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "false" ]
}

@test "first release moves latest when only prereleases exist" {
  decide v0.1.0 'v0.1.0-rc.1
v0.1.0'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "false" ]
}

@test "a tag missing from the list is refused, not decided" {
  # An empty ls-remote or a checkout without tags must not move latest.
  decide v0.82.0
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" != "false" ]
}

@test "an empty SKIP_LATEST_TAGS is an empty list, not ask git" {
  # Guards the ${VAR+set} test: a plain -n check would fall through to git
  # and find v0.80.0 there, letting the script succeed. The tag lives in a
  # repository made here, not this one: CI checks this one out without tags,
  # where git would find nothing either and the test could not tell.
  make_repo v0.80.0
  SKIP_LATEST_TAGS='' run sh -c 'cd "$1" && "$2" v0.80.0 </dev/null' sh "$repo" "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "falls back to git tag when SKIP_LATEST_TAGS is unset" {
  # The CI path.
  make_repo v0.80.1 v0.81.0 v0.80.2
  run env -u SKIP_LATEST_TAGS sh -c 'cd "$1" && "$2" v0.80.2 </dev/null' sh "$repo" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "true" ]
}

@test "missing argument is a usage error" {
  SKIP_LATEST_TAGS='' run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "the decision goes to stdout and the reasoning to stderr" {
  SKIP_LATEST_TAGS='v0.81.0' run sh -c '"$1" v0.81.0 2>/dev/null' sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "numbered fork revisions sort numerically" {
  decide v0.60.1-custom.10 'v0.60.1-custom.9
v0.60.1-custom.10'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = false ]
}

@test "official and preview tags cannot block the fork channel" {
  decide v0.60.1-custom.1 'v0.99.0
v0.99.0-rc.1
v0.99.0-custom.1-rc.1
v0.60.1-custom.1'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = false ]
}

@test "maintenance fork releases cannot move latest backwards" {
  decide v0.59.9-custom.99 'v0.59.9-custom.99
v0.60.1-custom.1'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = true ]
}

@test "invalid downstream revision is never a stable release" {
  decide v0.60.1-custom.0 'v0.60.1-custom.0'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = true ]
  run "$SCRIPT" prepare v0.60.1-custom.0
  [ "$status" -ne 0 ]
}

@test "RPM metadata retains the custom prerelease revision" {
  tmp=$(mktemp -d)
  cp "${BATS_TEST_DIRNAME}/../../.goreleaser.yaml" "$tmp/.goreleaser.yaml"
  run env GITHUB_REF=refs/tags/v0.60.1-custom.10 sh -c 'cd "$1" && sh "$2"' \
    sh "$tmp" "${BATS_TEST_DIRNAME}/../rpm-provides.sh"
  [ "$status" -eq 0 ]
  grep -Fq '0.60.1~custom.10-1' "$tmp/.goreleaser.generated.yaml"
  ! grep -Fq '@RPM_EVR@' "$tmp/.goreleaser.generated.yaml"
}

@test "release provenance requires an annotated tag on an integrated commit" {
  make_repo v0.60.1
  git -C "$repo" update-ref refs/upstream-tags/v0.60.1 HEAD
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit --quiet --allow-empty -m downstream
  git -C "$repo" -c user.name=t -c user.email=t@example.com tag -a v0.60.1-custom.1 -m release
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  run sh -c 'cd "$1" && bash "$2" prepare v0.60.1-custom.1' sh "$repo" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$repo/.release/version")" = '0.60.1-custom.1' ]
  grep -Fq '"custom_revision": 1' "$repo/.release/release.json"
  git -C "$repo" tag v0.60.1-custom.2
  run sh -c 'cd "$1" && bash "$2" prepare v0.60.1-custom.2' sh "$repo" "$SCRIPT"
  [ "$status" -ne 0 ]
  git -C "$repo" update-ref refs/remotes/origin/main refs/upstream-tags/v0.60.1
  run sh -c 'cd "$1" && bash "$2" prepare v0.60.1-custom.1' sh "$repo" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "release verification rejects changed or unsigned artifacts" {
  make_repo v0.60.1-custom.1
  run python3 - "$SCRIPT" "$repo" "${BATS_TEST_DIRNAME}/../../.goreleaser.yaml" <<'PYTEST'
import json, os, shutil, sys, types
from pathlib import Path
from unittest import mock
source = Path(sys.argv[1]).read_text().split("<<'RELEASE_POLICY_PY'\n", 1)[1].split("\nRELEASE_POLICY_PY", 1)[0]
policy = types.ModuleType("release_policy")
exec(compile(source, "release_policy", "exec"), policy.__dict__)
shutil.copyfile(sys.argv[3], Path(sys.argv[2]) / ".goreleaser.yaml")
os.chdir(sys.argv[2])
assets = Path("assets"); assets.mkdir()
tag = "v0.60.1-custom.1"
targets = policy.image_targets(tag)
assert len(targets) >= 6
images = {image: dict(latest=latest, digest="sha256:" + "b" * 64) for image, latest in targets.items()}
files = {"version": tag[1:], "install.sh": "installer", "signing-key.asc": "public key",
         "archive.tar.gz": "archive", "release.json": json.dumps(dict(tag=tag, commit=policy.run("git", "rev-parse", "HEAD"))),
         "images.json": json.dumps(dict(tag=tag, images=images))}
for name, data in files.items(): (assets / name).write_text(data)
def checksums():
    (assets / "SHA256SUMS").write_text("".join(f"{policy.digest(assets / name)}  {name}\n" for name in sorted(files)))
checksums()
policy.verify(tag, assets)
with mock.patch.object(policy.subprocess, "run", return_value=policy.subprocess.CompletedProcess([], 0, '{"draft": false}', '')):
    try: policy.check_draft(tag)
    except ValueError: pass
    else: raise AssertionError("published release overwrite accepted")
(assets / "archive.tar.gz").write_text("tampered")
try: policy.verify(tag, assets)
except ValueError: pass
else: raise AssertionError("tampered artifact accepted")
checksums()
(assets / "unsigned.txt").write_text("unsigned")
try: policy.verify(tag, assets)
except ValueError: pass
else: raise AssertionError("unsigned asset accepted")
PYTEST
  [ "$status" -eq 0 ]
}

@test "the sync workflow mirrors only upstream/main with an exact lease" {
  tmp=$(mktemp -d)
  run python3 - "${BATS_TEST_DIRNAME}/../../.github/workflows/sync-main.yml" "$tmp" <<'PYTEST'
"""Verify exact mirror updates against local repositories, without network access."""

import json
import sys
import textwrap
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

lines = Path(sys.argv[1]).read_text().splitlines()
marker = lines.index("      - name: Align the reserved upstream/main mirror")
assert lines[marker + 1] == "        run: |"
body = []
for line in lines[marker + 2:]:
    if line.strip() and not line.startswith("          "): break
    body.append(line)
SCRIPT = Path(sys.argv[2]) / "mirror.sh"
SCRIPT.write_text(textwrap.dedent("\n".join(body)) + "\n")
OFFICIAL = "https://github.com/netbirdio/netbird.git"
MIRROR = "refs/heads/upstream/main"


class MirrorMainTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.official = self.root / "official"
        self.fork = self.root / "fork.git"
        self.work = self.root / "work"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
        self.env.pop("GITHUB_STEP_SUMMARY", None)
        for repo in (self.official, self.work):
            repo.mkdir()
            self.git(repo, "init", "--quiet", "--template=", "--initial-branch=main")
            self.git(repo, "config", "user.name", "Mirror Test")
            self.git(repo, "config", "user.email", "mirror@example.com")
        self.git(self.root, "init", "--quiet", "--bare", "--template=", str(self.fork))
        (self.official / "README.md").write_text("official\n")
        self.commit(self.official, "official base")
        (self.work / "README.md").write_text("downstream\n")
        self.downstream = self.commit(self.work, "downstream base")
        self.git(self.work, "remote", "add", "origin", str(self.fork))
        # Rewrite the hard-coded official URL only in this fixture's local config.
        self.git(self.work, "config", f"url.{self.official.as_uri()}.insteadOf", OFFICIAL)
        self.git(self.work, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/heads/release-0.60")
        (self.work / "uncommitted.txt").write_text("keep this working file\n")
        self.status = self.git(self.work, "status", "--porcelain")

    def git(self, repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args],
                                       env=self.env, text=True, stderr=subprocess.STDOUT).strip()

    def commit(self, repo, message):
        self.git(repo, "add", ".")
        self.git(repo, "commit", "--quiet", "-m", message)
        return self.git(repo, "rev-parse", "HEAD")

    def remote_head(self, ref=MIRROR):
        return self.git(self.fork, "rev-parse", "--verify", ref)

    def sync(self, success=True, environment=None):
        result = subprocess.run(["bash", str(SCRIPT)], cwd=self.work,
                                env=environment or self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, "synchronization should have refused this update")
        self.assertEqual(self.remote_head("refs/heads/main"), self.downstream)
        self.assertEqual(self.remote_head("refs/heads/release-0.60"), self.downstream)
        self.assertEqual(self.git(self.work, "rev-parse", "HEAD"), self.downstream)
        self.assertEqual(self.git(self.work, "status", "--porcelain"), self.status)
        self.assertEqual((self.work / "uncommitted.txt").read_text(), "keep this working file\n")
        return result

    def test_creates_only_the_reserved_mirror_branch(self):
        self.sync()
        self.assertEqual(self.remote_head(), self.git(self.official, "rev-parse", "HEAD"))
        branches = self.git(self.fork, "for-each-ref", "--format=%(refname)", "refs/heads/").splitlines()
        self.assertEqual(set(branches), {MIRROR, "refs/heads/main", "refs/heads/release-0.60"})

    def test_advances_to_official_main_and_is_idempotent(self):
        self.sync()
        (self.official / "CHANGELOG.md").write_text("new official change\n")
        latest = self.commit(self.official, "official update")
        self.sync()
        self.assertEqual(self.remote_head(), latest)
        self.assertIn("already matches", self.sync().stdout)

    def test_discards_downstream_only_commits_on_the_reserved_mirror(self):
        self.sync()
        self.git(self.work, "push", "--force", "origin", f"{self.downstream}:{MIRROR}")
        self.assertEqual(self.remote_head(), self.downstream)
        self.sync()
        self.assertEqual(self.remote_head(), self.git(self.official, "rev-parse", "HEAD"))

    def test_tracks_a_rewritten_official_main_without_rebasing(self):
        self.sync()
        self.git(self.official, "checkout", "--quiet", "--orphan", "replacement")
        self.git(self.official, "rm", "--quiet", "-rf", ".")
        (self.official / "README.md").write_text("rewritten official history\n")
        rewritten = self.commit(self.official, "rewritten official root")
        self.git(self.official, "branch", "-M", "main")
        self.sync()
        self.assertEqual(self.remote_head(), rewritten)

    def test_fetch_failure_keeps_the_existing_mirror(self):
        self.sync()
        previous = self.remote_head()
        self.git(self.official, "update-ref", "-d", "refs/heads/main")
        self.sync(success=False)
        self.assertEqual(self.remote_head(), previous)

    def test_exact_lease_preserves_a_concurrent_remote_write(self):
        self.sync()
        (self.official / "CHANGELOG.md").write_text("official advancement\n")
        self.commit(self.official, "new official commit")
        # Replace the remote ref just before the real push. A plain --force would
        # overwrite it; the observed-SHA lease must instead reject the push.
        real_git = shutil.which("git", path=self.env["PATH"])
        shim_dir = self.root / "bin"
        shim_dir.mkdir()
        shim = shim_dir / "git"
        marker = self.root / "raced"
        shim.write_text(
            "#!/usr/bin/env python3\nimport os, subprocess, sys\nfrom pathlib import Path\n"
            f"real_git = {json.dumps(real_git)}\nmarker = Path({json.dumps(str(marker))})\n"
            "if 'push' in sys.argv[1:] and not marker.exists():\n"
            f"    subprocess.run([real_git, '--git-dir', {json.dumps(str(self.fork))}, "
            f"'update-ref', {json.dumps(MIRROR)}, {json.dumps(self.downstream)}], check=True)\n"
            "    marker.write_text('changed')\n"
            "os.execv(real_git, [real_git, *sys.argv[1:]])\n"
        )
        shim.chmod(0o755)
        environment = dict(self.env, PATH=str(shim_dir) + os.pathsep + self.env["PATH"])
        self.sync(success=False, environment=environment)
        self.assertTrue(marker.exists(), "fixture must change the branch before the push")
        self.assertEqual(self.remote_head(), self.downstream, "a concurrent update must remain untouched")


if __name__ == "__main__":
    unittest.main(argv=["mirror"], verbosity=1)
PYTEST
  [ "$status" -eq 0 ]
}

installer_fixture() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/fixtures" "$tmp/payload"
  printf '#!/bin/sh\necho 0.60.1-custom.1\n' > "$tmp/payload/netbird"
  chmod +x "$tmp/payload/netbird"
  tar -czf "$tmp/fixtures/netbird_0.60.1-custom.1_darwin_amd64.tar.gz" -C "$tmp/payload" netbird
  (cd "$tmp/fixtures" && shasum -a 256 netbird_0.60.1-custom.1_darwin_amd64.tar.gz > SHA256SUMS)
  printf 'signature fixture\n' > "$tmp/fixtures/SHA256SUMS.asc"
  printf 'trusted key fixture\n' > "$tmp/public-key.asc"
  cat > "$tmp/bin/uname" <<'SH'
#!/bin/sh
case "$1" in -m) echo x86_64 ;; *) echo Darwin ;; esac
SH
  cat > "$tmp/bin/sudo" <<'SH'
#!/bin/sh
exec "$@"
SH
  cat > "$tmp/bin/gpg" <<'SH'
#!/bin/sh
case "$*" in *--verify*) [ "${REJECT_SIGNATURE:-0}" != 1 ] || exit 19 ;; esac
exit 0
SH
  cat > "$tmp/bin/curl" <<'SH'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
case "$url" in
  */releases/latest) printf '{"tag_name":"v0.60.1-custom.1"}\n' ;;
  *)
    file="$INSTALL_FIXTURES/${url##*/}"
    test -f "$file" || exit 7
    if [ -n "$output" ]; then cp "$file" "$output"; else cat "$file"; fi
    ;;
esac
SH
  chmod +x "$tmp/bin/"*
}

run_installer() {
  run env PATH="$tmp/bin:$PATH" TMPDIR="$tmp" INSTALL_FIXTURES="$tmp/fixtures" \
    NETBIRD_RELEASE=latest NETBIRD_REPOSITORY_OWNER=qiudesong GITHUB_TOKEN='' \
    NETBIRD_GPG_KEY="$tmp/public-key.asc" NETBIRD_INSTALL_DIR="$tmp/installed" \
    NETBIRD_INSTALL_SERVICE=false REJECT_SIGNATURE="${1:-0}" \
    sh "${BATS_TEST_DIRNAME}/../install.sh"
}

@test "installer keeps the full fork version and installs only the verified CLI" {
  installer_fixture
  run_installer
  [ "$status" -eq 0 ]
  [ -x "$tmp/installed/netbird" ]
  cmp "$tmp/payload/netbird" "$tmp/installed/netbird"
}

@test "installer refuses an archive with a changed checksum" {
  installer_fixture
  printf tampered >> "$tmp/fixtures/netbird_0.60.1-custom.1_darwin_amd64.tar.gz"
  run_installer
  [ "$status" -ne 0 ]
  [ ! -e "$tmp/installed/netbird" ]
}

@test "installer refuses a rejected release signature" {
  installer_fixture
  run_installer 1
  [ "$status" -ne 0 ]
  [ ! -e "$tmp/installed/netbird" ]
}
