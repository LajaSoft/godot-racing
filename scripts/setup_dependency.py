"""Fetch the exact godot-cpp commit without silently replacing local work."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ref", required=True)
    args = parser.parse_args()
    dependency = ROOT / "godot-cpp"
    if not (dependency / ".git").exists():
        dependency.mkdir(exist_ok=True)
        subprocess.run(["git", "init", str(dependency)], check=True)
        subprocess.run(["git", "-C", str(dependency), "remote", "add", "origin",
                        "https://github.com/godotengine/godot-cpp.git"], check=True)
        subprocess.run(["git", "-C", str(dependency), "fetch", "--depth", "1", "origin", args.ref], check=True)
        subprocess.run(["git", "-C", str(dependency), "checkout", "--detach", "FETCH_HEAD"], check=True)
    actual = subprocess.check_output(["git", "-C", str(dependency), "rev-parse", "HEAD"], text=True).strip()
    if actual != args.ref:
        raise SystemExit(f"godot-cpp is {actual}, expected {args.ref}. Use a separate checkout for another API version.")
    print(f"godot-cpp pinned at {actual}")


if __name__ == "__main__":
    main()
