"""Run from the repository root after make; succeeds when the pathname bug occurs."""
import os
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
env = dict(os.environ, LUA_PATH="./src/?.lua;;", LUA_CPATH="./src/?.so;;")
env["LD_LIBRARY_PATH"] = str(root / "src") + ":" + env.get("LD_LIBRARY_PATH", "")
with tempfile.TemporaryDirectory(prefix="emulator-dump-review-") as temp:
    snapshot = str(Path(temp) / "machine")
    create = "local c=require('cartesi'); local m <close> = c.machine({ram={length=0x1000}}); m:store(arg[1])"
    subprocess.run(["lua5.4", "-", snapshot], input=create, cwd=root, env=env,
                   text=True, check=True, timeout=30)
    for name, should_succeed in (("plain", True), ("trial (1)", False)):
        destination = Path(temp) / name
        command = ["lua5.4", "src/cartesi-machine.lua", "--load=" + snapshot,
                   "--dump-memory-ranges=" + str(destination), "--max-mcycle=0",
                   "--no-init-splash", "--quiet"]
        result = subprocess.run(command, cwd=root, env=env, text=True,
                                capture_output=True, timeout=30)
        print(repr(name), "exit:", result.returncode, "created:", destination.exists())
        assert (result.returncode == 0) == should_succeed, result.stderr
        assert destination.exists() == should_succeed
        if not should_succeed:
            print(result.stderr.strip())
            assert "Syntax error" in result.stderr or "syntax error" in result.stderr
print("BUG 004 reproduced: the CLI rejects a legitimate directory name")
