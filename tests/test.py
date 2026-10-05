#!/usr/bin/env python3
"""Runs tests/run.luau under the `luau` CLI.

The CLI gives every required module its own read-only globals, so a test
can't install a `tern` global the plugin's modules would see. This bundles
the plugin and the tests into one chunk instead: each file becomes a
function, `require("./x")` becomes a lookup, and `tern` is one shared local.

    python3 tests/test.py
"""

import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = [
    "lib/util.luau", "lib/parse.luau", "lib/config.luau", "lib/git.luau",
    "lib/model.luau", "lib/view.luau", "lib/link.luau", "lib/diff_block.luau", "host.luau", "window.luau",
    "tests/fixtures.luau", "tests/stub.luau", "tests/run.luau",
]
REQUIRE = re.compile(r'require\("([^"]+)"\)')


def module_name(path):
    return os.path.splitext(path)[0]


def resolve(src, rel):
    base = os.path.dirname(src)
    return os.path.normpath(os.path.join(base, rel))


def wrap(path):
    with open(os.path.join(ROOT, path)) as f:
        text = f.read()
    text = REQUIRE.sub(lambda m: f'__require("{resolve(path, m.group(1))}")', text)
    # Exported type aliases are only legal at the top level of a chunk.
    text = re.sub(r"^export type ", "type ", text, flags=re.M)
    return f'__modules["{module_name(path)}"] = function(...)\n{text}\nend\n'


def main():
    parts = [
        "local tern = nil",
        "local __modules, __loaded = {}, {}",
        "local function __require(name)",
        "\tif __loaded[name] == nil then",
        "\t\tlocal f = __modules[name] or error('no module ' .. name)",
        "\t\t__loaded[name] = f() or true",
        "\tend",
        "\treturn __loaded[name]",
        "end",
        "local function __reload(name) __loaded[name] = nil; return __require(name) end",
    ]
    parts += [wrap(p) for p in FILES]
    parts.append('__require("tests/run")')
    bundle = "\n".join(parts)
    # The tests set the shared stub and re-run host.luau per test.
    bundle = bundle.replace("tern = S.tern", "tern = S.tern", 1)
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as f:
        f.write(bundle)
        path = f.name
    try:
        r = subprocess.run(["luau", path])
    finally:
        os.unlink(path)
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
