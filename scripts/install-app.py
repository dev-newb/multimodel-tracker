#!/usr/bin/env python3
"""Stage and verify the new bundle, stop the old process, then swap. Never copy over a live app."""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


def running_pids(bundle):
    executable = str(bundle.resolve() / "Contents/MacOS/MultimodelTracker")
    listing = subprocess.check_output(["ps", "-axww", "-o", "pid=,comm="], text=True)
    result = []
    for line in listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == executable:
            result.append(int(fields[0]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("build/Multimodel Tracker.app"))
    parser.add_argument("--destination", type=Path, default=Path.home()/"Applications/Multimodel Tracker.app")
    parser.add_argument("--launch", action="store_true", help="Launch after installing; otherwise leave stopped")
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.destination.resolve()
    if source == destination or not (source/"Contents/MacOS/MultimodelTracker").is_file():
        parser.error("Source must be a built app distinct from the destination")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".mmt-install-", dir=destination.parent) as temporary:
        staging = Path(temporary)/destination.name
        backup = Path(temporary)/"previous.app"
        shutil.copytree(source, staging, symlinks=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staging)], check=True)
        for pid in running_pids(destination):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic()+10
        while running_pids(destination):
            if time.monotonic() >= deadline:
                raise RuntimeError("App did not exit; installation aborted without replacing it")
            time.sleep(0.1)
        if destination.exists():
            destination.rename(backup)
        try:
            staging.rename(destination)
        except Exception:
            if backup.exists():
                backup.rename(destination)
            raise
    print("Installed verified bundle; previous process was stopped before replacement.")
    if args.launch:
        subprocess.run(["open", str(destination)], check=True)
    else:
        print("Tracker remains stopped.")


if __name__ == "__main__":
    main()
