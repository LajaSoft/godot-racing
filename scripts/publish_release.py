"""Publish a verified immutable gd-plug tag and draft release in GitHub Actions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd=None, env=None):
    return subprocess.check_output(command, cwd=cwd, env=env, text=True).strip()


def verify_release(directory, source_tag, source_commit):
    metadata = json.loads((directory / "release.json").read_text())
    version = metadata["version"]
    if source_tag != f"v{version}" or not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise RuntimeError("Source tag/commit must match the release version")
    if metadata["source_commit"] != source_commit or metadata["source_dirty"]:
        raise RuntimeError("Refusing publication of an uncommitted or mismatched source build")
    if metadata.get("distribution_tag") != f"addon-v{version}" or metadata.get("platform") != "linux.x86_64":
        raise RuntimeError("Unsupported distribution tag or platform")
    archive = directory / f"godot-ffb-{version}-linux-x86_64.zip"
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    if (directory / "SHA256SUMS").read_text().strip() != f"{checksum}  {archive.name}":
        raise RuntimeError("Release archive checksum does not match SHA256SUMS")
    with zipfile.ZipFile(archive) as z:
        if any(not name.startswith("addons/ffb/") or ".." in Path(name).parts for name in z.namelist()):
            raise RuntimeError("Unexpected path in addon archive")
        if json.loads(z.read("addons/ffb/BUILD.json")) != metadata:
            raise RuntimeError("Release metadata differs from archive provenance")
        for name, expected in metadata["sha256"].items():
            if hashlib.sha256(z.read(name)).hexdigest() != expected:
                raise RuntimeError(f"Addon file checksum mismatch: {name}")
    return metadata, archive, checksum


def github_release(repository, source_tag, token):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/releases/tags/{source_tag}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def publish(directory, repository, source_tag, source_commit, token):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise RuntimeError("Expected GitHub owner/repository")
    metadata, archive, checksum = verify_release(directory, source_tag, source_commit)
    existing_release = github_release(repository, source_tag, token)
    if existing_release is not None and not existing_release["draft"]:
        raise RuntimeError("Refusing to modify an already published GitHub release")
    remote = f"https://github.com/{repository}.git"
    distribution_tag = metadata["distribution_tag"]
    provenance = {"source_commit": source_commit, "archive_sha256": checksum, "version": metadata["version"]}
    with tempfile.TemporaryDirectory(prefix="ffb-publish-") as temporary:
        workspace = Path(temporary)
        askpass = workspace / "askpass.sh"
        # The file contains no token; Git obtains it from the job environment.
        askpass.write_text('#!/bin/sh\ncase "$1" in *Username*) printf "%s\\n" "x-access-token";; *) printf "%s\\n" "$GH_TOKEN";; esac\n')
        askpass.chmod(0o700)
        environment = dict(os.environ, GH_TOKEN=token, GIT_ASKPASS=str(askpass), GIT_TERMINAL_PROMPT="0")
        tag_ref = f"refs/tags/{distribution_tag}"
        found = subprocess.run(["git", "-c", "credential.helper=", "ls-remote", "--exit-code", "--tags", remote, tag_ref], env=environment, text=True, capture_output=True)
        snapshot = workspace / "snapshot"
        snapshot.mkdir()
        run(["git", "init", "-b", "distribution"], cwd=snapshot)
        if found.returncode == 0:
            run(["git", "-c", "credential.helper=", "fetch", "--depth", "1", remote, tag_ref], cwd=snapshot, env=environment)
            previous = json.loads(run(["git", "show", "FETCH_HEAD:SOURCE.json"], cwd=snapshot))
            if previous != provenance:
                raise RuntimeError("Existing distribution tag has different provenance; it will not be replaced")
        else:
            if found.returncode != 2:
                raise RuntimeError("Cannot inspect distribution tag: " + found.stderr)
            with zipfile.ZipFile(archive) as z:
                z.extractall(snapshot)
            shutil.copyfile(snapshot / "addons/ffb/LICENSE", snapshot / "LICENSE")
            (snapshot / "SOURCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
            (snapshot / "README.md").write_text(f"# Godot FFB {metadata['version']}\n\nPrebuilt Linux addon for gd-plug.\n\nSource: https://github.com/{repository}/tree/{source_commit}\n")
            run(["git", "add", "."], cwd=snapshot)
            run(["git", "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com", "commit", "-m", f"Package Godot FFB {metadata['version']} from {source_commit}"], cwd=snapshot)
            run(["git", "tag", distribution_tag], cwd=snapshot)
            run(["git", "-c", "credential.helper=", "push", remote, tag_ref], cwd=snapshot, env=environment)
        if existing_release is None:
            subprocess.run(["gh", "release", "create", source_tag, "--repo", repository, "--verify-tag", "--draft", "--title", f"Godot FFB {metadata['version']} — Moza / Linux", "--notes-file", str(ROOT / "docs/release-notes.md")], env=environment, check=True)
        subprocess.run(["gh", "release", "upload", source_tag, "--repo", repository, "--clobber", str(archive), str(directory / "SHA256SUMS"), str(directory / "release.json")], env=environment, check=True)
    print(f"Prepared {distribution_tag} and draft release {source_tag}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise SystemExit("GH_TOKEN is required; publication is intended for the release workflow")
    publish(args.directory, os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_REF_NAME"], os.environ["GITHUB_SHA"], token)


if __name__ == "__main__":
    main()
