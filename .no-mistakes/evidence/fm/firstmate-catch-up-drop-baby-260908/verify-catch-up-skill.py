"""Semantic verification of the /catch-up skill as an agent consumes it.

Parses the skill file into (a) its YAML frontmatter, which is the discovery
contract Claude/Codex skill loaders read, and (b) the ordered step list under
Phase 2, then resolves the skill's own "Phase 2 step N" cross-references
against that parsed structure.
"""
import re, sys, yaml, pathlib

p = pathlib.Path(sys.argv[1])
text = p.read_text()
_, fm, body = text.split("---\n", 2)
meta = yaml.safe_load(fm)

print("== skill discovery record (what the captain's agent lists for /catch-up) ==")
print("name:", meta["name"])
print("user-invocable:", meta["user-invocable"])
print("description:", " ".join(meta["description"].split())[:400])
targets = [t for t in ["firstmate", "quota-axi", "baby-menu", "npm axi tools", "no-mistakes"]
           if t in meta["description"]]
print("targets advertised:", targets)
assert "baby-menu" not in text, "baby-menu still referenced somewhere in the skill"
assert targets == ["firstmate", "quota-axi", "npm axi tools", "no-mistakes"], targets

# --- target map table ---
rows = [l for l in body.splitlines() if l.startswith("| ") and "---" not in l]
header, rows = rows[0], rows[1:]
tools = [r.split("|")[1].strip() for r in rows]
print("\n== target map rows ==")
for t in tools:
    print(" -", t)
assert tools == ["firstmate", "quota-axi",
                 "gh-axi, lavish-axi, chrome-devtools-axi, tasks-axi",
                 "no-mistakes"], tools

# --- Phase 2 ordered landing steps ---
phase2 = body.split("## Phase 2")[1]
order = phase2.split("### Order")[1]
steps = {}
cur = None
for line in order.splitlines():
    m = re.match(r"^(\d+)\. \*\*(.+?)\*\*", line)
    if m:
        cur = int(m.group(1))
        steps[cur] = {"title": m.group(2), "body": line}
    elif cur and line.startswith("   "):
        steps[cur]["body"] += "\n" + line
    elif cur and not line.strip():
        continue
    elif cur and not line.startswith(" "):
        cur = None
print("\n== Phase 2 landing order (as parsed) ==")
for n, s in sorted(steps.items()):
    print(f"  step {n}: {s['title']}")

# --- resolve every "Phase 2 step N" cross-reference in the skill ---
refs = re.findall(r"Phase 2 step (\d+)([^\n.]*)", body)
print("\n== cross-reference resolution ==")
ok = True
for n, tail in refs:
    n = int(n)
    step = steps.get(n)
    print(f'  "Phase 2 step {n}{tail}" -> ' + (f"step {n}: {step['title']}" if step else "UNRESOLVED"))
    assert step, f"Phase 2 step {n} does not exist"

# the two references fixed in 734eff7 must land on the step that actually
# carries the behavior they point at
inst = steps[1]["body"]
assert "pnpm install --frozen-lockfile" in inst and "rebuild" in inst, \
    "step 1 is not the quota-axi install/rebuild step"
assert "Never `npm update -g quota-axi`" in steps[2]["body"], \
    "step 2 does not carry the destructive-command guard"
print("\n  step 1 carries the dependency install + rebuild approval points: OK")
print("  step 2 carries the 'Never npm update -g quota-axi' guard: OK")

# --- no baby-menu work is ever requested ---
for phase in ["Phase 0", "Phase 1", "Phase 2", "Rollback", "Cleanup"]:
    seg = body.split(f"## {phase}")[-1]
    assert "baby-menu" not in seg
print("\n  no fetch/merge/tag/rebuild of baby-menu remains in any phase: OK")
print("\nALL CHECKS PASSED")
