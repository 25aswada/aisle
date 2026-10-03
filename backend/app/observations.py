"""Shopper reports ("Found it" / "Not here") and the consensus drawn from them.

A zone becomes the answer only when at least MIN_AGREEING_REPORTS different
shoppers found the item there and they outnumber "not here" reports for it.
Typed aisle text is shown only when that many shoppers typed the same thing.
"""
from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import LocationObservation, ProductConcept, Store, StoreZone

MIN_AGREEING_REPORTS = 2
HIGH_CONFIDENCE_REPORTS = 3


@dataclass
class ReportCounts:
    found: int = 0
    not_here: int = 0


@dataclass
class Consensus:
    zone: StoreZone
    aisle: str | None
    counts: ReportCounts
    confidence: str


def _reporter(observation: LocationObservation) -> str:
    # Anonymous device ids dedupe repeat taps; reports without one count separately.
    return observation.device_id or f"report-{observation.id}"


def normalize_aisle(text: str | None) -> str | None:
    text = " ".join((text or "").split())
    return text.lower() or None


def observations_for(
    db: Session, store: Store, concept: ProductConcept | None, item_normalized: str
) -> list[LocationObservation]:
    condition = (
        LocationObservation.concept_id == concept.id if concept is not None
        else LocationObservation.item_normalized == item_normalized
    )
    return list(db.scalars(
        select(LocationObservation).where(LocationObservation.store_id == store.id, condition)
    ))


def counts_by_zone(observations: list[LocationObservation]) -> dict[int, ReportCounts]:
    reporters: dict[tuple[int, str], set[str]] = defaultdict(set)
    for observation in observations:
        if observation.zone_id is not None:
            reporters[(observation.zone_id, observation.verdict)].add(_reporter(observation))
    counts: dict[int, ReportCounts] = defaultdict(ReportCounts)
    for (zone_id, verdict), people in reporters.items():
        if verdict == "found":
            counts[zone_id].found = len(people)
        elif verdict == "not_here":
            counts[zone_id].not_here = len(people)
    return counts


def consensus(observations: list[LocationObservation]) -> Consensus | None:
    counts = counts_by_zone(observations)
    candidates = [
        (c.found, -c.not_here, zone_id) for zone_id, c in counts.items()
        if c.found >= MIN_AGREEING_REPORTS and c.found > c.not_here
    ]
    if not candidates:
        return None
    _, _, zone_id = max(candidates)
    zone_counts = counts[zone_id]
    in_zone = [o for o in observations if o.zone_id == zone_id and o.verdict == "found"]
    zone = in_zone[0].zone

    aisle_reporters: dict[str, set[str]] = defaultdict(set)
    spellings: dict[str, Counter] = defaultdict(Counter)
    for observation in in_zone:
        key = normalize_aisle(observation.aisle_text)
        if key:
            aisle_reporters[key].add(_reporter(observation))
            spellings[key][observation.aisle_text.strip()] += 1
    agreed = [(len(people), key) for key, people in aisle_reporters.items() if len(people) >= MIN_AGREEING_REPORTS]
    aisle = spellings[max(agreed)[1]].most_common(1)[0][0] if agreed else None

    confident = zone_counts.found >= HIGH_CONFIDENCE_REPORTS and zone_counts.not_here == 0
    return Consensus(zone=zone, aisle=aisle, counts=zone_counts, confidence="high" if confident else "medium")
