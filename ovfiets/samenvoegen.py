#!/usr/bin/env python3
"""
Voegt de output van scrape_ovfiets.py samen tot doorlopende reeksen.

De site geeft per locatie alleen de laatste ~4 weken (meetpunt per ~15 min).
Door scrape_ovfiets.py regelmatig te draaien en de uitkomst hier samen te voegen,
groeit per locatie één reeks die verder teruggaat dan het venster van de site.

Gebruik
-------
  py samenvoegen.py <map-met-scrape-output> <doelmap>

  <doelmap>/historie/<code>/<JJJJ-MM>.csv  reeks per locatie per maand (ontdubbeld op timestamp)
  <doelmap>/locaties_live_reeks.csv  aangevuld met locaties_live.csv als die in de output staat

Alleen standaardbibliotheek.
"""

import csv
import datetime as dt
import glob
import os
import sys

KOLOMMEN = ["locatie_code", "locatie_naam", "timestamp", "datum", "weekdag", "tijd", "beschikbaar"]


def schrijf_maand(uit, nieuwe_rijen):
    """Voegt rijen samen met één maandbestand; geeft het aantal nieuwe meetpunten terug."""
    rijen = {}
    if os.path.exists(uit):
        with open(uit, encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                rijen[r["timestamp"]] = r
    voor = len(rijen)
    for r in nieuwe_rijen:
        rijen[r["timestamp"]] = r                  # nieuwste scrape wint (zelfde meetpunt)
    if len(rijen) == voor and os.path.exists(uit):
        return 0                                   # niets nieuws: bestand ongemoeid laten
    tmp = uit + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=KOLOMMEN, extrasaction="ignore")
        w.writeheader()
        for ts in sorted(rijen, key=dt.datetime.fromisoformat):
            w.writerow(rijen[ts])
    os.replace(tmp, uit)
    return len(rijen) - voor


def voeg_historie_samen(bron, doel):
    """Schrijft per locatie per maand een bestand: historie/<code>/<JJJJ-MM>.csv.
    Zo verandert bij een nieuwe run alleen de lopende maand, wat de git-historie klein houdt."""
    locaties, nieuw_totaal = 0, 0
    for pad in sorted(glob.glob(os.path.join(bron, "*_historie.csv"))):
        code = os.path.basename(pad)[: -len("_historie.csv")]
        per_maand = {}
        with open(pad, encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                per_maand.setdefault(r["timestamp"][:7], []).append(r)
        map_ = os.path.join(doel, "historie", code)
        os.makedirs(map_, exist_ok=True)
        for maand, rijen in per_maand.items():
            nieuw_totaal += schrijf_maand(os.path.join(map_, maand + ".csv"), rijen)
        locaties += 1
    return locaties, nieuw_totaal


def voeg_live_toe(bron, doel):
    pad = os.path.join(bron, "locaties_live.csv")
    if not os.path.exists(pad):
        return 0
    uit = os.path.join(doel, "locaties_live_reeks.csv")
    nieuw = not os.path.exists(uit)
    with open(pad, encoding="utf-8", newline="") as f:
        rijen = list(csv.reader(f))
    if len(rijen) < 2:
        return 0
    if not nieuw:
        with open(uit, encoding="utf-8", newline="") as f:
            al = {r["opgehaald_op"] for r in csv.DictReader(f)}
        if rijen[1][0] in al:                      # deze momentopname staat er al in
            return 0
    with open(uit, "a", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerows(rijen if nieuw else rijen[1:])
    return len(rijen) - 1


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    bron, doel = sys.argv[1], sys.argv[2]
    os.makedirs(doel, exist_ok=True)
    locaties, nieuw = voeg_historie_samen(bron, doel)
    live = voeg_live_toe(bron, doel)
    print("%d locaties samengevoegd, %d nieuwe meetpunten; %d live-regels toegevoegd" % (locaties, nieuw, live))
    return 0


if __name__ == "__main__":
    sys.exit(main())
