#!/usr/bin/env python3
"""Static validation of the Logic App workflow definitions in workflows/.

Catches the classes of mistake that Azure only reports at deployment time, or
that deploy silently and then misbehave at runtime:

  * nesting depth over the documented limit of 8
  * more than 500 actions in one workflow
  * a runAfter pointing at something that is not a sibling in the same scope
  * a runAfter cycle, or an invalid runAfter status
  * a parameter referenced but not declared, or declared but never used
  * a variable read before the action that initializes it
  * unbalanced parentheses or quotes in an expression
  * an outputs() / body() / actions() reference that reaches across a scope
    boundary. Reaching into an Until loop from outside it is accepted by Azure
    but silently reads only the final iteration.

Usage:
  scripts/validate-workflows.py [workflow.json ...]

With no arguments, validates every *.json in workflows/.
Exit codes: 0 valid, 1 problems found, 2 usage error.
"""

import json
import pathlib
import re
import sys

# Documented Azure Logic Apps limits.
# https://learn.microsoft.com/azure/logic-apps/logic-apps-limits-and-config#workflow-limits
MAX_DEPTH = 8
MAX_ACTIONS = 500
MAX_EXPRESSION_CHARS = 8192

VALID_STATUSES = {"Succeeded", "Failed", "Skipped", "TimedOut"}
CONTAINERS = ("actions", "else")


def walk_scopes(actions, scope_name="root"):
    """Yield (scope_name, {action_name: action}) for every action scope."""
    yield scope_name, actions
    for name, action in actions.items():
        for key in CONTAINERS:
            block = action.get(key)
            if isinstance(block, dict):
                nested = block.get("actions", block) if key == "else" else block
                if isinstance(nested, dict) and nested:
                    yield from walk_scopes(nested, f"{scope_name}/{name}.{key}")


def walk_depths(actions, depth=1, path="root"):
    """Yield (depth, path) for every action."""
    for name, action in actions.items():
        here = f"{path}/{name}"
        yield depth, here
        for key in CONTAINERS:
            block = action.get(key)
            if isinstance(block, dict):
                nested = block.get("actions", block) if key == "else" else block
                if isinstance(nested, dict) and nested:
                    yield from walk_depths(nested, depth + 1, here)


def topo_order(actions):
    """Action names in runAfter order, or None if the graph is cyclic."""
    remaining = dict(actions)
    ordered, guard = [], 0
    while remaining and guard <= len(actions):
        ready = [
            name for name, action in remaining.items()
            if all(target in ordered or target not in actions
                   for target in (action.get("runAfter") or {}))
        ]
        if not ready:
            return None
        for name in sorted(ready):
            ordered.append(name)
            del remaining[name]
        guard += 1
    return ordered if not remaining else None


def validate(path):
    """Validate one definition. Returns (problems, facts, notes)."""
    problems, notes = [], []
    definition = json.loads(path.read_text())
    label = path.name
    root_actions = definition["actions"]
    body = json.dumps(definition)

    # --- limits ---------------------------------------------------------------
    all_depths = list(walk_depths(root_actions))
    deepest, deepest_path = max(all_depths, key=lambda pair: pair[0])
    if deepest > MAX_DEPTH:
        problems.append(
            f"{label}: nesting depth {deepest} exceeds the limit of {MAX_DEPTH} "
            f"at {deepest_path}. Merge the new test into an existing condition's "
            f"expression instead of adding a nested If (see CONTRIBUTING.md)."
        )
    if len(all_depths) > MAX_ACTIONS:
        problems.append(f"{label}: {len(all_depths)} actions exceeds the limit of {MAX_ACTIONS}")

    # --- scope integrity ------------------------------------------------------
    scope_of = {}
    for scope_name, actions in walk_scopes(root_actions):
        for action_name in actions:
            scope_of[action_name] = scope_name

    for scope_name, actions in walk_scopes(root_actions):
        for name, action in actions.items():
            run_after = action.get("runAfter") or {}
            for target in run_after:
                if target not in actions:
                    problems.append(
                        f"{label}: {scope_name}/{name} runAfter '{target}' is not a sibling"
                    )
            bad = {s for statuses in run_after.values() for s in statuses} - VALID_STATUSES
            if bad:
                problems.append(f"{label}: {scope_name}/{name} invalid runAfter status {sorted(bad)}")

        if topo_order(actions) is None:
            problems.append(f"{label}: {scope_name} contains a runAfter cycle")

        entry_points = [n for n, a in actions.items() if not a.get("runAfter")]
        if len(entry_points) > 1:
            # Legal: these run in parallel. Worth surfacing because parallel
            # branches writing the same variable race.
            notes.append(f"{label}: {scope_name} has parallel entry points {sorted(entry_points)}")

    # An action may only reference its own scope or an enclosing one.
    for scope_name, actions in walk_scopes(root_actions):
        for name, action in actions.items():
            own = {k: v for k, v in action.items() if k not in CONTAINERS}
            text = json.dumps(own)
            for target in sorted(set(re.findall(r"(?:outputs|body|actions)\(\s*'([^']+)'\s*\)", text))):
                if target == name or target not in scope_of:
                    continue
                target_scope = scope_of[target]
                visible = scope_name == target_scope or scope_name.startswith(target_scope + "/")
                if not visible:
                    problems.append(
                        f"{label}: {scope_name}/{name} references '{target}' across a scope "
                        f"boundary (it lives in {target_scope})"
                    )

    # --- parameters -----------------------------------------------------------
    declared = set(definition.get("parameters", {}))
    referenced = set(re.findall(r"parameters\(\s*'([^']+)'\s*\)", body))
    for name in sorted(referenced - declared):
        problems.append(f"{label}: parameters('{name}') referenced but not declared")
    for name in sorted(declared - referenced):
        problems.append(
            f"{label}: parameter '{name}' is declared but never referenced. "
            f"Either wire it up or remove it."
        )

    # --- variables ------------------------------------------------------------
    order = topo_order(root_actions) or []
    initialized = {}
    for position, name in enumerate(order):
        action = root_actions[name]
        if action.get("type") == "InitializeVariable":
            for variable in action["inputs"]["variables"]:
                initialized[variable["name"]] = position

    used = set(re.findall(r"variables\(\s*'([^']+)'\s*\)", body))
    for name in sorted(used - set(initialized)):
        problems.append(f"{label}: variables('{name}') used but never initialized")

    for name, action in root_actions.items():
        position = order.index(name) if name in order else -1
        for variable in sorted(set(re.findall(r"variables\(\s*'([^']+)'\s*\)", json.dumps(action)))):
            if variable in initialized and position >= 0 and initialized[variable] > position:
                problems.append(
                    f"{label}: {name} reads variables('{variable}') before it is initialized"
                )

    # --- expressions ----------------------------------------------------------
    expressions = re.findall(r'"(@\{?[^"]*)"', body)
    for expression in expressions:
        if expression.count("(") != expression.count(")"):
            problems.append(f"{label}: unbalanced parentheses in: {expression[:100]}")
        if expression.count("'") % 2:
            problems.append(f"{label}: odd number of quotes in: {expression[:100]}")
        if len(expression) > MAX_EXPRESSION_CHARS:
            problems.append(
                f"{label}: expression of {len(expression)} chars exceeds "
                f"{MAX_EXPRESSION_CHARS}: {expression[:80]}"
            )

    facts = {
        "actions": len(all_depths),
        "depth": deepest,
        "depth_path": deepest_path,
        "parameters": sorted(declared),
        "variables": sorted(initialized),
        "expressions": len(expressions),
    }
    return problems, facts, notes


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    if argv:
        paths = [pathlib.Path(a) for a in argv]
    else:
        root = pathlib.Path(__file__).resolve().parent.parent
        paths = sorted((root / "workflows").glob("*.json"))

    missing = [p for p in paths if not p.is_file()]
    if missing:
        print(f"error: not found: {', '.join(str(m) for m in missing)}", file=sys.stderr)
        return 2
    if not paths:
        print("error: no workflow definitions to validate", file=sys.stderr)
        return 2

    all_problems, all_notes = [], []
    for path in paths:
        problems, facts, notes = validate(path)
        all_problems.extend(problems)
        all_notes.extend(notes)
        print(f"{path.name}")
        print(f"  actions      : {facts['actions']} / {MAX_ACTIONS}")
        print(f"  nesting depth: {facts['depth']} / {MAX_DEPTH}"
              f"{'  <-- AT LIMIT' if facts['depth'] == MAX_DEPTH else ''}")
        print(f"                 {facts['depth_path']}")
        print(f"  parameters   : {', '.join(facts['parameters'])}")
        print(f"  variables    : {len(facts['variables'])}")
        print(f"  expressions  : {facts['expressions']}")

    if all_notes:
        print("\nnotes (legal, but worth knowing):")
        for note in all_notes:
            print(f"  - {note}")

    print()
    if all_problems:
        print(f"{len(all_problems)} PROBLEM(S):")
        for problem in all_problems:
            print(f"  - {problem}")
        return 1
    print("VALID: limits, scopes, parameters, variables and expressions all check out")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
