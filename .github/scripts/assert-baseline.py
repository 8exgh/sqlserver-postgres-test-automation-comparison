#!/usr/bin/env python3
"""Gate a VSTest .trx against a list of tests that are expected to fail.

The parity suite does not go green, by design: two tests fail on a structural
difference between the engines that tests/README.md documents as a judgement call
rather than a defect. "Zero failures" is therefore the wrong gate, and simply
filtering those two out is not much better - it would hide the day one of them
starts passing, which would mean the documented analysis had gone stale.

So the gate is set equality. The set of failed tests must be exactly the set named
in the expected-failures file. Anything else fails the build, in either direction:

    an unexpected test failed        -> a regression
    an expected failure now passes   -> the docs are out of date

Usage:
    assert-baseline.py <results.trx> <expected-failures.txt>

Exit codes:  0 baseline held   1 baseline broken   2 could not run the check
"""

from __future__ import annotations

import os
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path
from typing import NoReturn

# Every element in a .trx carries this namespace.
NS = {"t": "http://microsoft.com/schemas/VisualStudio/TeamTest/2010"}

# Outcomes that are neither a pass nor a failure (e.g. "NotExecuted" for a skip).
PASSED = "Passed"
FAILED = "Failed"


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def read_expected(path: Path) -> set[str]:
    """One fully-qualified test name per line; '#' comments and blanks ignored."""
    if not path.exists():
        fail(f"expected-failures file not found: {path}")

    names = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            names.add(line)
    return names


def read_results(path: Path) -> list[tuple[str, str]]:
    """Return one (fully-qualified test name, outcome) pair per executed case.

    A .trx splits what we need across two sections: TestDefinitions carries the
    class and method names, UnitTestResult carries the outcome, and they are
    joined on executionId. The name is built from className + name rather than
    taken from the result's testName attribute, because testName carries the
    argument list for a [Theory] and would not match an entry in
    expected-failures.txt.

    That makes the name non-unique - this suite is heavily data-driven, so one
    [Theory] contributes many cases under a single name. Hence a list of pairs
    rather than a dict: collapsing by name here would let a passing case overwrite
    a failing sibling and hide it from the gate.
    """
    if not path.exists():
        fail(
            f"no test results at {path}.\n"
            "       The test run produced no .trx, so it failed before executing any "
            "test -\n"
            "       check the step above for a build error or a database that never "
            "came up."
        )

    try:
        root = ElementTree.parse(path).getroot()
    except ElementTree.ParseError as error:
        fail(f"{path} is not valid XML: {error}")

    names_by_execution: dict[str, str] = {}
    for definition in root.findall(".//t:TestDefinitions/t:UnitTest", NS):
        method = definition.find("t:TestMethod", NS)
        execution = definition.find("t:Execution", NS)
        if method is None or execution is None:
            continue
        class_name = method.get("className", "")
        # className is assembly-qualified ("Ns.Class, Asm, Version=...") in some
        # writers; keep only the type name.
        class_name = class_name.split(",", 1)[0]
        names_by_execution[execution.get("id", "")] = f"{class_name}.{method.get('name', '')}"

    results: list[tuple[str, str]] = []
    for result in root.findall(".//t:Results/t:UnitTestResult", NS):
        name = names_by_execution.get(result.get("executionId", ""))
        if name:
            results.append((name, result.get("outcome", "")))

    if not results:
        fail(f"{path} contains no test results")
    return results


def summarise(lines: list[str]) -> None:
    """Echo to stdout, and to the job summary when running under Actions."""
    text = "\n".join(lines)
    print(text)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        fail(f"usage: {Path(argv[0]).name} <results.trx> <expected-failures.txt>")

    results = read_results(Path(argv[1]))
    expected = read_expected(Path(argv[2]))

    all_names = {name for name, _ in results}
    # A name covers many cases when it is a [Theory], so one failing case makes the
    # whole name failed. "Passing" therefore means passing everywhere.
    failed = {name for name, outcome in results if outcome == FAILED}
    passed = {name for name, outcome in results if outcome == PASSED} - failed
    other = sorted(
        {(name, outcome) for name, outcome in results if outcome not in (PASSED, FAILED)}
    )

    passed_cases = sum(1 for _, outcome in results if outcome == PASSED)
    failed_cases = sum(1 for _, outcome in results if outcome == FAILED)

    unexpected_failures = sorted(failed - expected)
    now_passing = sorted(expected & passed)
    # Named in the file but absent from this run - renamed, removed, or filtered out.
    missing = sorted(expected - all_names)

    lines = [
        "## Test baseline",
        "",
        f"`{Path(argv[1]).name}` — **{passed_cases} passed, {failed_cases} failed**"
        f" of {len(results)} cases.",
        "",
    ]
    if other:
        lines.append(f"{len(other)} case(s) neither passed nor failed:")
        lines += [f"- `{name}` — {outcome}" for name, outcome in other]
        lines.append("")

    ok = True

    if unexpected_failures:
        ok = False
        lines.append(f"### ❌ {len(unexpected_failures)} unexpected failure(s)")
        lines.append("")
        lines += [f"- `{name}`" for name in unexpected_failures]
        lines.append("")
        lines.append("A test that was passing has regressed.")
        lines.append("")

    if now_passing:
        ok = False
        lines.append(f"### ❌ {len(now_passing)} expected failure(s) now PASS")
        lines.append("")
        lines += [f"- `{name}`" for name in now_passing]
        lines.append("")
        lines.append(
            "This is good news that needs recording: remove the entry from "
            "`.github/expected-failures.txt` and update the "
            '"Known failures" section of `tests/README.md`, which still '
            "describes it as an accepted divergence."
        )
        lines.append("")

    if missing:
        ok = False
        lines.append(f"### ❌ {len(missing)} expected failure(s) did not run")
        lines.append("")
        lines += [f"- `{name}`" for name in missing]
        lines.append("")
        lines.append("Renamed, removed, or filtered out of this run — the entry is stale.")
        lines.append("")

    if ok:
        lines.append("### ✅ Baseline held")
        lines.append("")
        if expected:
            lines.append("Both failures are the documented structural divergence:")
            lines.append("")
            lines += [f"- `{name}`" for name in sorted(expected)]
        else:
            lines.append("No failures, and none were expected.")

    summarise(lines)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
