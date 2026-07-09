"""Shared shell classification for the codex-worker enforcement hooks."""

from __future__ import annotations

import re
import shlex


RUNNER_CALL = re.compile(
    r"^\s*(?:~|\$HOME|/[^\s`;|&<>()]+?)/\.claude/agents/bin/"
    r"codex-run\.sh(?:\s|$)"
)
RUNNER_DANGER = re.compile(r"[`<>]|\$\((?!pwd\))")
# --verify only prints ok/forged (no [codex-session:] footer, no content) and
# --extract-review post-processes a prior run — neither is a fresh forward, so
# neither may bind proof. --recover is DELIBERATELY excluded from this set: it
# re-emits a completed run's real archived content + footer through the runner
# (deterministic, runner-owned, and only when the archive genuinely exists), so
# its tool_result IS valid forwarding proof. The stop-gate's own stripped-relay
# remedy tells the forwarder to run it, and a cross-session recover leg would
# otherwise be blocked as "not emitted by this transcript" (v3.7 high review).
PROOFLESS_RUNNER_FLAGS = {"--verify", "--extract-review"}


def _heredoc_on_line(line: str) -> tuple[str, bool] | None:
    """Return the first real, unquoted heredoc delimiter on *line*."""

    quote: str | None = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == "\\" and i + 1 < len(line):
                i += 2
                continue
            if c == '"':
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < len(line):
            i += 2
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            continue
        if c == "#" and (i == 0 or line[i - 1].isspace()):
            break
        if line.startswith("<<", i):
            m = re.match(
                r"<<(?P<tabs>-?)[ \t]*(?:'(?P<sq>\w+)'|\"(?P<dq>\w+)\"|(?P<bare>\w+))",
                line[i:],
            )
            if m:
                return (m.group("sq") or m.group("dq") or m.group("bare"),
                        m.group("tabs") == "-")
        i += 1
    return None


def strip_heredocs(command: str) -> str:
    """Remove actual heredoc bodies while retaining their command headers."""

    lines, out, i = command.split("\n"), [], 0
    while i < len(lines):
        header = lines[i]
        out.append(header)
        spec = _heredoc_on_line(header)
        i += 1
        if spec:
            delimiter, strip_tabs = spec
            while i < len(lines):
                candidate = lines[i].lstrip("\t") if strip_tabs else lines[i]
                if candidate == delimiter:
                    i += 1
                    break
                i += 1
    return "\n".join(out)


def shell_segments(command: str) -> list[str]:
    normalized = strip_heredocs(command or "")
    normalized = re.sub(r"\\\n\s*", " ", normalized)
    return [segment.strip() for segment in re.split(r"[;\n|&]+", normalized)]


def runner_seg_ok(segment: str, *, proof_only: bool = False) -> bool:
    """Classify a runner command; proof mode accepts only launch/poll forms."""

    if not RUNNER_CALL.match(segment) or RUNNER_DANGER.search(segment):
        return False
    if proof_only:
        try:
            argv = shlex.split(segment)
        except ValueError:
            return False
        if any(arg in PROOFLESS_RUNNER_FLAGS for arg in argv[1:]):
            return False
    return True


def runner_invoked(command: str, *, proof_only: bool = False) -> bool:
    return any(runner_seg_ok(segment, proof_only=proof_only)
               for segment in shell_segments(command))


def simple_shell_variables(text: str) -> list[str] | None:
    """Return simple variable references, or None for any other dollar form."""

    names: list[str] = []
    i = 0
    while i < len(text):
        if text.startswith("$(pwd)", i):
            i += len("$(pwd)")
            continue
        if text[i] != "$":
            i += 1
            continue
        m = re.match(r"\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})", text[i:])
        if not m:
            return None
        names.append(m.group(1) or m.group(2))
        i += len(m.group(0))
    return names
