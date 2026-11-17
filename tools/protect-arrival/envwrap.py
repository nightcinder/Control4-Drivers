import os
import sys


def _parse_env_file(path):
    values = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            if key:
                # later duplicates override earlier ones (systemd EnvironmentFile semantics)
                values[key] = val
    return values


def main():
    envfile = sys.argv[1]
    cmd = sys.argv[2:]
    if os.path.exists(envfile):
        for key, val in _parse_env_file(envfile).items():
            # container-provided environment still wins
            if key not in os.environ:
                os.environ[key] = val
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
