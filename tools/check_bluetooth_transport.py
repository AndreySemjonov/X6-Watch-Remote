"""Compile the actual Watch transport against a CoreBluetooth test double.

This exercises delegate ordering on Windows; Apple SDK compilation and physical
radio/runtime validation remain separate gates. No device connection is made.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc")
if not SWIFTC:
    raise SystemExit("swiftc is required")

with tempfile.TemporaryDirectory(prefix="x6-transport-check-") as temporary:
    out = Path(temporary)
    windows = os.name == "nt"
    suffix = ".dll" if windows else ".dylib"
    for module, sources in [
        ("CoreBluetooth", [ROOT / "apple/TransportChecks/CoreBluetooth.swift"]),
        ("X6Core", sorted((ROOT / "apple/Packages/X6Core/Sources/X6Core").glob("*.swift"))),
    ]:
        library = out / (("" if windows else "lib") + module + suffix)
        subprocess.run([SWIFTC, "-emit-library", "-emit-module", "-module-name", module,
                        "-emit-module-path", str(out / (module + ".swiftmodule")),
                        *map(str, sources), "-o", str(library)], check=True)
    executable = out / ("RecoveryChecks.exe" if windows else "RecoveryChecks")
    subprocess.run([SWIFTC, "-parse-as-library", "-I", str(out), "-L", str(out),
                    "-lCoreBluetooth", "-lX6Core",
                    str(ROOT / "apple/WatchApp/BluetoothCamera.swift"),
                    str(ROOT / "apple/TransportChecks/RecoveryChecks.swift"),
                    "-o", str(executable)], check=True)
    environment = os.environ.copy()
    key = "PATH" if windows else "DYLD_LIBRARY_PATH"
    environment[key] = str(out) + os.pathsep + environment.get(key, "")
    subprocess.run([str(executable)], env=environment, check=True)
