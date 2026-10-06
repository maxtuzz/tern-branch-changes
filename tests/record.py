#!/usr/bin/env python3
"""Builds a sample repo and records the git output the plugin asks for.

Writes tests/fixtures.luau: a table from the argv the plugin runs (joined
with spaces) to {status, stdout, stderr}. The test stub of
tern.process.run answers from it, so when lib/git.luau changes the argv it
issues, re-run this script.

    python3 tests/record.py
"""

import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures.luau")
PREFIX = ["git", "--no-optional-locks", "-c", "core.quotepath=off", "-c", "color.ui=never"]
LOG_FORMAT = "%x1e%H%x1f%h%x1f%an%x1f%ct%x1f%s"
ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "Ada",
    "GIT_AUTHOR_EMAIL": "ada@example.com",
    "GIT_COMMITTER_NAME": "Ada",
    "GIT_COMMITTER_EMAIL": "ada@example.com",
    "GIT_CONFIG_NOSYSTEM": "1",
    "HOME": "/nonexistent",
    "LC_ALL": "C",
}


def git(repo, *args, date=None):
    env = dict(ENV)
    if date:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = date
    return subprocess.run(
        ["git", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", *args],
        cwd=repo, env=env, check=True, capture_output=True, text=True,
    ).stdout.strip()


def write(repo, path, text):
    full = os.path.join(repo, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(text)


def build(repo):
    git(repo, "init", "-q")
    git(repo, "remote", "add", "origin", "https://example.invalid/sample.git")
    day = [0]

    def commit(msg):
        day[0] += 1
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", msg, date=f"2026-01-{day[0]:02d}T12:00:00Z")

    write(repo, "a.txt", "one\n")
    write(repo, "lib/util.lua", "return {}\n")
    commit("main: init")
    write(repo, "README.md", "# sample\n")
    commit("main: readme")
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")

    git(repo, "checkout", "-qb", "feat")
    write(repo, "a.txt", "one\ntwo\n")
    commit("feat: grow a")
    os.makedirs(os.path.join(repo, "docs"))
    git(repo, "mv", "a.txt", "docs/b c.txt")
    commit("feat: move a")
    git(repo, "update-ref", "refs/remotes/origin/feat", "HEAD")
    git(repo, "config", "branch.feat.remote", "origin")
    git(repo, "config", "branch.feat.merge", "refs/heads/feat")
    write(repo, "new.lua", "print('hi')\n")
    commit("feat: add new.lua")

    git(repo, "checkout", "-q", "main")
    write(repo, "main-only.txt", "x\n")
    commit("main: later work")
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    git(repo, "checkout", "-q", "feat")
    day[0] += 1
    git(repo, "merge", "-q", "--no-edit", "origin/main", date=f"2026-01-{day[0]:02d}T12:00:00Z")

    write(repo, "new.lua", "print('hello')\n")
    git(repo, "add", "new.lua")
    write(repo, "lib/util.lua", "return { x = 1 }\n")
    write(repo, "notes with space.md", "todo\n")


def lua_string(data: bytes) -> str:
    out = ['"']
    for b in data:
        c = chr(b)
        if c == "\\" or c == '"':
            out.append("\\" + c)
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif 32 <= b < 127:
            out.append(c)
        else:
            out.append("\\%03d" % b)
    out.append('"')
    return "".join(out)


def main():
    tmp = tempfile.mkdtemp(prefix="bc-fixture-")
    repo = os.path.realpath(os.path.join(tmp, "repo"))
    os.makedirs(repo)
    try:
        build(repo)
        mb = git(repo, "merge-base", "origin/main", "HEAD")
        rng = f"{mb}..HEAD"
        commits = git(repo, "rev-list", rng).split()
        cmds = [
            ["rev-parse", "--show-toplevel"],
            ["config", "--get", "user.name"],
            ["config", "--get", "core.fsmonitor"],
            ["rev-parse", "-q", "--verify", "HEAD"],
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
            ["diff", "--numstat", "-z", "--"],
            ["diff", "--cached", "--numstat", "-z", "-M", "--"],
            ["merge-base", "origin/main", "HEAD"],
            ["log", "--no-color", "--format=" + LOG_FORMAT, "-n", "200", rng, "--"],
            ["rev-list", "--count", rng, "--"],
            ["rev-list", "-n", "200", "origin/feat..HEAD", "--"],
            ["diff", "--shortstat", mb, "HEAD", "--"],
            ["diff", "--no-color", "--cached", "-M", "--", "new.lua"],
            ["diff", "--no-color", "--", "lib/util.lua"],
            ["diff", "--no-color", "--no-index", "--", "/dev/null", "notes with space.md"],
        ]
        for ref in ["origin/dev", "origin/main", "origin/HEAD"]:
            cmds.append(["rev-parse", "-q", "--verify", "--end-of-options", ref + "^{commit}"])
        for sha in commits:
            cmds.append(["diff-tree", "-r", "-z", "--raw", "--numstat", "-M", "--root",
                         "--no-commit-id", "--diff-merges=first-parent", sha, "--"])
            names = git(repo, "diff-tree", "-r", "--name-status", "-M", "--root", "--no-commit-id",
                        "--diff-merges=first-parent", sha).splitlines()
            for line in names:
                parts = line.split("\t")
                paths = parts[1:]
                cmds.append(["show", "--no-color", "--format=", "-M", "--diff-merges=first-parent",
                             sha, "--", *paths])

        lines = ["-- Generated by tests/record.py; do not edit.", "return {",
                 f"\troot = {lua_string(repo.encode())},",
                 f"\tmerge_base = {lua_string(mb.encode())},",
                 "\tcommits = {" + ", ".join(lua_string(c.encode()) for c in commits) + "},",
                 "\truns = {"]
        for args in cmds:
            r = subprocess.run(PREFIX + args, cwd=repo, env=ENV, capture_output=True)
            key = " ".join(PREFIX + args)
            lines.append(f"\t\t[{lua_string(key.encode())}] = {{ status = {r.returncode}, "
                         f"stdout = {lua_string(r.stdout)}, stderr = {lua_string(r.stderr)} }},")
        lines += ["\t},", "}", ""]
        with open(OUT, "w") as f:
            f.write("\n".join(lines))
        print(f"wrote {OUT} ({len(cmds)} commands)")
    finally:
        shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
