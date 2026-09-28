#!/usr/bin/env python3
"""
Scraper voor OV-fiets beschikbaarheid (ovfietsbeschikbaar.nl).

De site is server-rendered; grafiekdata staat als HTML-escaped JSON in het
attribuut data-symfony--ux-chartjs--chart-view-value. Geen browser nodig.

Gebruik
-------
  py scrape_ovfiets.py rtd001 ut020 --out ./data     scrape deze locaties
  py scrape_ovfiets.py --all --out ./data            alle ~285 locaties
  py scrape_ovfiets.py --index --out ./data          alleen live-snapshot (1 request)
  py scrape_ovfiets.py --list                        toon alle codes + namen

Per locatie komen er precies drie bestanden in --out:
  <code>_historie.csv   ~4 weken, meetpunt per ~15 min
  <code>_meta.json      live stand + samenvatting + checkresultaten
  <code>_raw.html       ruwe /verloop-pagina

Exitcode 0 = alles geslaagd, 1 = minstens één locatie faalde of een check viel om.
Alleen standaardbibliotheek.
"""

import argparse
import csv
import datetime as dt
import html
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

BASE = "https://ovfietsbeschikbaar.nl"
UA = "ovfiets-research/1.0"
MIN_INTERVAL = 2.0  # seconden tussen requests; de site kent geen rate-limit-header
WEEKDAGEN = ["maandag", "dinsdag", "woensdag", "donderdag",
             "vrijdag", "zaterdag", "zondag"]

_laatste_request = 0.0


class ScrapeFout(Exception):
    """Locatie kon niet verwerkt worden; andere locaties gaan gewoon door."""


# --------------------------------------------------------------------------
# ophalen
# --------------------------------------------------------------------------

def fetch(pad, pogingen=4):
    """Haal een pagina op. Tempo via MIN_INTERVAL, retries met oplopende backoff.

    Let op: een read-timeout komt naar buiten als TimeoutError/OSError, NIET als
    URLError. Die apart afvangen, anders sloopt één trage pagina de hele run.
    """
    global _laatste_request
    url = BASE + pad
    for poging in range(1, pogingen + 1):
        wacht = MIN_INTERVAL - (time.monotonic() - _laatste_request)
        if wacht > 0:
            time.sleep(wacht)
        _laatste_request = time.monotonic()
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise ScrapeFout("404 op %s — locatiecode bestaat niet" % pad)
            if e.code < 500 or poging == pogingen:
                raise ScrapeFout("HTTP %d op %s" % (e.code, pad))
            time.sleep(5 * poging)
        except urllib.error.URLError as e:
            if poging == pogingen:
                raise ScrapeFout("netwerkfout op %s: %s" % (pad, e.reason))
            time.sleep(5 * poging)
        except (TimeoutError, OSError) as e:
            if poging == pogingen:
                raise ScrapeFout("time-out op %s: %s" % (pad, e))
            time.sleep(5 * poging)
    raise ScrapeFout("onbereikbaar: %s" % pad)


# --------------------------------------------------------------------------
# parsen
# --------------------------------------------------------------------------

CHART_RE = re.compile(r'data-symfony--ux-chartjs--chart-view-value="(.*?)"', re.S)


def charts(pagina):
    """Alle Chart.js-configuraties op een pagina.

    De JSON is entity-escaped (&quot; &#x7B; &#x3A;); zonder html.unescape
    faalt json.loads gegarandeerd.
    """
    return [json.loads(html.unescape(m.group(1))) for m in CHART_RE.finditer(pagina)]


LEEFTIJD_RE = re.compile(
    r"van\s*<strong>\s*(\d+)\s*(minuut|minuten|uur|uren)\s*geleden\s*</strong>", re.I)
NAAM_RE = re.compile(r'<h2 class="display-6[^"]*">\s*(.*?)\s*</h2>', re.S)
TOTAAL_RE = re.compile(r"Totaal aantal\s*<i[^>]*></i>\s*:\s*(\d+)")


def parse_live(pagina, code):
    """Naam, live stand, capaciteit en versheid van /locatie/<code>."""
    doughnuts = [c for c in charts(pagina) if c.get("type") == "doughnut"]
    if not doughnuts:
        raise ScrapeFout("geen doughnut-grafiek gevonden — site-layout gewijzigd?")
    reeks = doughnuts[0]["data"]["datasets"][0]["data"]
    beschikbaar, verhuurd = int(reeks[0]), int(reeks[1])

    m = NAAM_RE.search(pagina)
    if not m:
        raise ScrapeFout("locatienaam niet gevonden — site-layout gewijzigd?")
    naam = html.unescape(re.sub(r"<[^>]*>", "", m.group(1))).strip()

    capaciteit = beschikbaar + verhuurd
    m = TOTAAL_RE.search(pagina)
    capaciteit_tekst = int(m.group(1)) if m else None
    if capaciteit_tekst is not None and capaciteit_tekst != capaciteit:
        # geen fout: melden en de expliciete tekstwaarde aanhouden
        capaciteit = capaciteit_tekst

    # "Aantal licht verouderd": ontbreekt meestal, is transiënt.
    # Ontbreekt hij, dan None — nooit 0, want 0 beweert "zojuist gemeten".
    leeftijd = None
    m = LEEFTIJD_RE.search(pagina)
    if m:
        leeftijd = int(m.group(1)) * (60 if m.group(2).lower().startswith("u") else 1)

    return {
        "locatie_code": code,
        "locatie_naam": naam,
        "beschikbaar": beschikbaar,
        "verhuurd": verhuurd,
        "capaciteit": capaciteit,
        "capaciteit_uit_tekst": capaciteit_tekst,
        "data_leeftijd_min": leeftijd,
    }


def parse_verloop(pagina):
    """Meetpunten uit /locatie/<code>/verloop, chronologisch.

    LET OP: dataset['label'] is een weekdagnaam die er structureel één dag
    naast zit (geverifieerd 29/29). De weekdag wordt daarom altijd uit de
    tijdstempel berekend; het bronlabel wordt genegeerd.
    """
    lijnen = [c for c in charts(pagina) if c.get("type") == "line"]
    if not lijnen:
        raise ScrapeFout("geen lijngrafiek gevonden — site-layout gewijzigd?")
    datasets = lijnen[0]["data"]["datasets"]
    bronpunten = sum(len(ds["data"]) for ds in datasets)

    punten = []
    for ds in datasets:
        for p in ds["data"]:
            t = dt.datetime.fromisoformat(p["x"])   # tz-aware, Europe/Amsterdam
            punten.append((t, int(p["y"])))
    punten.sort(key=lambda r: r[0])
    return punten, bronpunten, len(datasets)


# --------------------------------------------------------------------------
# afgeleide waarden
# --------------------------------------------------------------------------

def dagen_met_gaten(punten):
    """Dagen waarop de feed duidelijk minder heeft geleverd dan normaal.

    Een dag telt als gat bij < 50% van de mediaan. Die mediaan wordt bepaald
    zonder de eerste en de laatste dag, en die twee worden zelf nooit geflagd:
    ze zijn inherent onvolledig (venstergrens / dag nog bezig).
    """
    per_dag = {}
    for t, _ in punten:
        per_dag[t.date()] = per_dag.get(t.date(), 0) + 1
    dagen = sorted(per_dag)
    if len(dagen) < 3:
        return []
    binnen = dagen[1:-1]
    drempel = statistics.median(per_dag[d] for d in binnen) * 0.5
    return [d.isoformat() for d in binnen if per_dag[d] < drempel]


def schrijf_csv(pad, live, punten):
    with open(pad, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["locatie_code", "locatie_naam", "timestamp",
                    "datum", "weekdag", "tijd", "beschikbaar"])
        for t, y in punten:
            w.writerow([live["locatie_code"], live["locatie_naam"], t.isoformat(),
                        t.date().isoformat(), WEEKDAGEN[t.weekday()],
                        t.strftime("%H:%M"), y])


def controleer(live, punten, bronpunten, csv_pad, meta_pad, raw_pad, bewaar_raw):
    """De vaste zelfcontroles, uitgevoerd op het weggeschreven CSV-bestand
    (niet op het geheugen), zodat ook schrijffouten opvallen.
    Geeft (naam, ok, toelichting, hard) per check; hard=False is een
    waarschuwing die de locatie niet laat mislukken."""
    waarden = [y for _, y in punten]
    tijden = [t for t, _ in punten]
    nu = dt.datetime.now(dt.timezone.utc)
    checks = []

    with open(csv_pad, encoding="utf-8", newline="") as f:
        rijen_uit_csv = list(csv.DictReader(f))
    rijen = len(rijen_uit_csv)
    checks.append(("rijen == bronpunten", rijen == bronpunten,
                   "%d vs %d" % (rijen, bronpunten), True))

    uniek = len(set(tijden)) == len(tijden)
    oplopend = tijden == sorted(tijden)
    checks.append(("timestamps uniek en oplopend", uniek and oplopend,
                   "uniek=%s oplopend=%s" % (uniek, oplopend), True))

    binnen_cap = max(waarden) <= live["capaciteit"]
    checks.append(("max <= capaciteit", binnen_cap,
                   "max=%d cap=%d%s" % (max(waarden), live["capaciteit"],
                                        "" if binnen_cap else "  LET OP: site toont dit zelf zo"), True))

    # Zacht: een stilgevallen feed is een eigenschap van de bron, geen scrapefout.
    # De site markeert zulke locaties zelf als "sterk verouderd" op /locaties.
    uren = (nu - max(tijden)).total_seconds() / 3600
    checks.append(("laatste meting < 24u oud", uren < 24, "%.1f uur" % uren, False))

    nodig = [csv_pad, meta_pad] + ([raw_pad] if bewaar_raw else [])
    bestanden = all(os.path.exists(p) and os.path.getsize(p) > 0 for p in nodig)
    checks.append(("bestanden aanwezig", bestanden, "%d verwacht" % len(nodig), True))

    # Leest de weekdagkolom terug uit de CSV en toetst hem tegen de datumkolom.
    # Vangt het overnemen van het foute bronlabel én schrijffouten.
    fout = sum(1 for r in rijen_uit_csv
               if r["weekdag"] != WEEKDAGEN[dt.date.fromisoformat(r["datum"]).weekday()])
    checks.append(("weekdag klopt met datum", fout == 0, "%d afwijkingen" % fout, True))

    verkeerd = {r["locatie_code"] for r in rijen_uit_csv} - {live["locatie_code"]}
    checks.append(("locatiecode overal correct", not verkeerd,
                   "ook gevonden: %s" % ", ".join(sorted(verkeerd)), True))

    return checks


# --------------------------------------------------------------------------
# per locatie
# --------------------------------------------------------------------------

def scrape(code, outdir, bewaar_raw=True):
    os.makedirs(outdir, exist_ok=True)
    csv_pad = os.path.join(outdir, "%s_historie.csv" % code)
    meta_pad = os.path.join(outdir, "%s_meta.json" % code)
    raw_pad = os.path.join(outdir, "%s_raw.html" % code)

    live_html = fetch("/locatie/%s" % code)
    live = parse_live(live_html, code)

    verloop_html = fetch("/locatie/%s/verloop" % code)
    if bewaar_raw:
        with open(raw_pad, "w", encoding="utf-8") as f:
            f.write(verloop_html)
    punten, bronpunten, n_datasets = parse_verloop(verloop_html)
    if not punten:
        raise ScrapeFout("historie is leeg")

    schrijf_csv(csv_pad, live, punten)

    waarden = [y for _, y in punten]
    tijden = [t for t, _ in punten]
    gaten = dagen_met_gaten(punten)
    meta = {
        "locatie_code": code,
        "locatie_naam": live["locatie_naam"],
        "opgehaald_op": dt.datetime.now().astimezone().isoformat(),
        "bron": BASE + "/locatie/%s/verloop" % code,
        "live": {
            "beschikbaar": live["beschikbaar"],
            "capaciteit": live["capaciteit"],
            "data_leeftijd_min": live["data_leeftijd_min"],
        },
        "historie": {
            "aantal_meetpunten": len(punten),
            "periode_van": min(tijden).isoformat(),
            "periode_tot": max(tijden).isoformat(),
            "aantal_dagen": len({t.date() for t in tijden}),
            "aantal_datasets_in_bron": n_datasets,
            "min": min(waarden),
            "max": max(waarden),
            "gemiddelde": round(sum(waarden) / len(waarden), 2),
            "nulmetingen": sum(1 for y in waarden if y == 0),
            "dagen_met_gaten": gaten,
        },
    }
    # meta eerst wegschrijven: de checks toetsen de bestanden op schijf,
    # dus die moeten er op dat moment al zijn.
    def bewaar():
        with open(meta_pad, "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)

    bewaar()
    checks = controleer(live, punten, bronpunten, csv_pad, meta_pad, raw_pad, bewaar_raw)
    meta["checks"] = {
        naam: ("OK" if ok else ("FOUT: " if hard else "WAARSCHUWING: ") + det)
        for naam, ok, det, hard in checks}
    bewaar()

    return meta, checks, live


# --------------------------------------------------------------------------
# index (/locaties): alle locaties in één request
# --------------------------------------------------------------------------

# Per <tr> parsen, niet over de hele pagina: locaties zonder live-getal tonen
# <td colspan="2">sterk verouderd</td> en hebben GEEN <td class="text-end">.
# Eén doorlopende regex slurpt dan het getal van de volgende rij op en laat die
# rij vallen — dat kostte 36 van de 285 locaties en gaf er 36 een fout aantal.
TR_RE = re.compile(r"<tr>(.*?)</tr>", re.S)
LINK_RE = re.compile(r'<a href="/locatie/([a-z0-9]+)">([^<]+)</a>')
AANTAL_RE = re.compile(r'<td class="text-end">\s*(\d+)\s*</td>')
BADGE_RE = re.compile(r'<span class="badge[^"]*">\s*(.*?)\s*</span>', re.S)


def index():
    """[(code, naam, live_aantal_of_None, status)] voor alle locaties, 1 request."""
    pagina = fetch("/locaties")
    rijen = []
    for blok in TR_RE.findall(pagina):
        m = LINK_RE.search(blok)
        if not m:
            continue
        a = AANTAL_RE.search(blok)
        b = BADGE_RE.search(blok)
        status = re.sub(r"\s+", " ", html.unescape(b.group(1))).strip() if b else ""
        rijen.append((m.group(1), html.unescape(m.group(2)).strip(),
                      int(a.group(1)) if a else None, status))
    if not rijen:
        raise ScrapeFout("geen locaties gevonden op /locaties — layout gewijzigd?")
    gevonden = len(set(LINK_RE.findall(pagina)))
    if len(rijen) < gevonden:
        raise ScrapeFout("index onvolledig: %d rijen voor %d locatielinks"
                         % (len(rijen), gevonden))
    return rijen


def schrijf_index(outdir):
    os.makedirs(outdir, exist_ok=True)
    rijen = index()
    pad = os.path.join(outdir, "locaties_live.csv")
    nu = dt.datetime.now().astimezone().isoformat()
    with open(pad, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["opgehaald_op", "locatie_code", "locatie_naam",
                    "beschikbaar", "status"])
        for c, n, a, st in rijen:
            w.writerow([nu, c, n, "" if a is None else a, st])
    return pad, rijen


# --------------------------------------------------------------------------

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="Scrape OV-fiets beschikbaarheid.")
    ap.add_argument("codes", nargs="*", help="locatiecodes, bv. rtd001 ut020")
    ap.add_argument("--all", action="store_true", help="alle locaties uit /locaties")
    ap.add_argument("--index", action="store_true",
                    help="alleen live-snapshot van alle locaties (1 request)")
    ap.add_argument("--list", action="store_true", help="toon codes + namen en stop")
    ap.add_argument("--out", default="./data", help="uitvoermap (default ./data)")
    ap.add_argument("--hervat", action="store_true",
                    help="sla locaties over die al een meta.json hebben")
    ap.add_argument("--no-raw", action="store_true",
                    help="bewaar de ruwe HTML niet (scheelt ~250 kB per locatie)")
    a = ap.parse_args()

    if a.list:
        for c, n, live, st in index():
            print("%-9s %-45s %-5s %s" % (c, n, "" if live is None else live, st))
        return 0

    if a.index:
        pad, rijen = schrijf_index(a.out)
        zonder = sum(1 for _, _, x, _ in rijen if x is None)
        print("%d locaties -> %s" % (len(rijen), pad))
        if zonder:
            print("%d daarvan zonder live-getal (bv. 'sterk verouderd')" % zonder)
        return 0

    codes = [c for c, _, _, _ in index()] if a.all else a.codes
    if not codes:
        ap.error("geef locatiecodes op, of --all / --index / --list")

    mislukt = []
    overgeslagen = 0
    for i, code in enumerate(codes, 1):
        kop = "[%d/%d] %s" % (i, len(codes), code)
        klaar = os.path.join(a.out, "%s_meta.json" % code)
        if a.hervat and os.path.exists(klaar) and os.path.getsize(klaar) > 0:
            overgeslagen += 1
            continue
        try:
            meta, checks, live = scrape(code, a.out, bewaar_raw=not a.no_raw)
        except ScrapeFout as e:
            print("%s  MISLUKT: %s" % (kop, e))
            mislukt.append((code, str(e)))
            continue
        except Exception as e:  # één stukke locatie mag de run niet afbreken
            print("%s  MISLUKT (onverwacht): %s: %s" % (kop, type(e).__name__, e))
            mislukt.append((code, "%s: %s" % (type(e).__name__, e)))
            continue

        h = meta["historie"]
        leeftijd = live["data_leeftijd_min"]
        print("%s  %s" % (kop, meta["locatie_naam"]))
        print("      live %d/%d%s" % (
            live["beschikbaar"], live["capaciteit"],
            "" if leeftijd is None else "  (meting %d min oud)" % leeftijd))
        print("      %d punten, %s t/m %s (%d dagen), min %d / max %d / gem %.1f" % (
            h["aantal_meetpunten"], h["periode_van"][:16], h["periode_tot"][:16],
            h["aantal_dagen"], h["min"], h["max"], h["gemiddelde"]))
        if h["nulmetingen"]:
            print("      %d nulmetingen (echte metingen, niet gefilterd)" % h["nulmetingen"])
        if h["dagen_met_gaten"]:
            print("      gaten in de feed: %s" % ", ".join(h["dagen_met_gaten"]))
        uit_grafiek = live["beschikbaar"] + live["verhuurd"]
        if live["capaciteit_uit_tekst"] not in (None, uit_grafiek):
            print("      LET OP: capaciteit grafiek=%d, tekst=%d — tekst aangehouden"
                  % (uit_grafiek, live["capaciteit_uit_tekst"]))
        hard = [(n, d) for n, ok, d, h in checks if not ok and h]
        zacht = [(n, d) for n, ok, d, h in checks if not ok and not h]
        for n, d in zacht:
            print("      WAARSCHUWING: %s (%s)" % (n, d))
        if hard:
            mislukt.append((code, "; ".join("%s (%s)" % (n, d) for n, d in hard)))
            for n, d in hard:
                print("      CHECK OMGEVALLEN: %s (%s)" % (n, d))
        else:
            print("      checks: %d/%d OK%s" % (
                len(checks) - len(zacht), len(checks),
                "" if not zacht else " (+%d waarschuwing)" % len(zacht)))

    if overgeslagen:
        print("\n%d locaties overgeslagen (al aanwezig)" % overgeslagen)
    if mislukt:
        print("\n%d van %d locaties niet in orde:" % (len(mislukt), len(codes)))
        for c, r in mislukt:
            print("  %s: %s" % (c, r))
        return 1
    print("\n%d locaties in orde -> %s" % (len(codes), os.path.abspath(a.out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
