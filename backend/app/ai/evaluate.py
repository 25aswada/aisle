"""Run the location eval cases against the configured provider.

    python -m backend.app.ai.evaluate            # model if ANTHROPIC_API_KEY is set
    python -m backend.app.ai.evaluate --fallback # deterministic fallback only
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from .catalog import layout_for_retailer
from .intent import parse_intent
from .providers import get_location_model
from .reasoning import LocationGuess, fallback_guess

CASES_PATH = Path(__file__).with_name("eval_cases.json")


def load_cases() -> list[dict]:
    return json.loads(CASES_PATH.read_text())


def check(case: dict, guess: LocationGuess) -> list[str]:
    problems = []
    if guess.department != case["department"]:
        problems.append(f"department {guess.department!r} != {case['department']!r}")
    lowered = [n.lower() for n in guess.neighbors]
    for neighbor in case["neighbors"]:
        if neighbor not in lowered:
            problems.append(f"missing neighbor {neighbor!r}")
    if guess.confidence != case["confidence"]:
        problems.append(f"confidence {guess.confidence} != {case['confidence']}")
    if guess.availability != case["availability"]:
        problems.append(f"availability {guess.availability} != {case['availability']}")
    return problems


def run(use_model: bool) -> int:
    model = get_location_model() if use_model else None
    failures = 0
    for case in load_cases():
        intent = parse_intent(case["query"])
        layout = layout_for_retailer(case["retailer"])
        guess = (model.locate(intent, case["retailer"], layout) if model else None) or fallback_guess(intent, layout)
        problems = check(case, guess)
        failures += bool(problems)
        status = "FAIL" if problems else "ok  "
        print(f"{status} [{guess.source}] {case['retailer']}: {case['query']} -> {guess.department}"
              + (f"  ({'; '.join(problems)})" if problems else ""))
    print(f"\n{len(load_cases()) - failures}/{len(load_cases())} passed"
          f" using {'model ' + model.name if model else 'deterministic fallback'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run(use_model="--fallback" not in sys.argv))
