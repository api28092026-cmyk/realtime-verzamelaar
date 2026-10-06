#!/usr/bin/env python3
"""
Archiveert afgesloten dagen uit data/. Alleen standaardbibliotheek.

  archiveer.py pack          comprimeert elk dagbestand van voor vandaag (UTC) naar archive/<reeks>_<JJJJ-MM-DD>.csv.gz
                             en drukt per regel de maand en de bestandsnaam af ("JJJJ-MM archive/...")
  archiveer.py prune D ...   verwijdert de dagbestanden van die dagen uit data/

De workflow zet de bestanden in release hf-JJJJ-MM voordat er iets wordt verwijderd.
"""
import gzip
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

DATA = Path("data")
OUT = Path("archive")
# map in data/ -> naam van de reeks in het archief
REEKSEN = {
    "laadpunten/wijzigingen": "laadpunten_wijzigingen",
    "laadpunten/stand": "laadpunten_stand",
    "laadpunten/kenmerken": "laadpunten_kenmerken",
    "parkeren/npr": "parkeren_npr",
    "parkeren/amsterdam": "parkeren_amsterdam",
    "parkeren/vrachtwagen": "parkeren_vrachtwagen",
    "parkeren/garages": "parkeren_garages",
    "parkeren/catalogus": "parkeren_catalogus",
    "runs": "runs",
}


def dagbestanden():
    vandaag = f"{datetime.now(timezone.utc):%Y-%m-%d}"
    for map_, reeks in REEKSEN.items():
        for p in sorted((DATA / map_).glob("*.csv*")):
            dag = p.name[:10]
            if len(dag) == 10 and dag < vandaag:
                yield dag, reeks, p


def pack() -> None:
    OUT.mkdir(exist_ok=True)
    for dag, reeks, p in dagbestanden():
        doel = OUT / f"{reeks}_{dag}.csv.gz"
        if p.suffix == ".gz":
            shutil.copyfile(p, doel)
        else:
            doel.write_bytes(gzip.compress(p.read_bytes(), 9))
        print(dag[:7], doel.as_posix())


def prune(dagen: list) -> None:
    for dag, _, p in list(dagbestanden()):
        if dag in dagen:
            p.unlink()


if __name__ == "__main__":
    opdracht, rest = sys.argv[1], sys.argv[2:]
    {"pack": pack, "prune": lambda: prune(rest)}[opdracht]()
