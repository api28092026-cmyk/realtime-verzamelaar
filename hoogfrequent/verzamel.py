#!/usr/bin/env python3
"""
Hoogfrequente verzamelaar, draait elke 5 minuten. Slaat alleen WIJZIGINGEN op, met het tijdstip van de bron.
Alleen standaardbibliotheek.

Bronnen (open data, geen key):
  - NDW DOT-NL: status van alle publieke laadpunten (ververst elke minuut; geen historie bij de bron)
  - RDW Nationaal Parkeerregister (SPDP): vrije plekken per garage met openbare dynamische data
  - Gemeente Amsterdam: vrije plekken in garages en P+R
  - NDW: bezetting van truckparkings

Output (map data/; op GitHub de branch hoogfrequent-data, afgesloten dagen als release hf-JJJJ-MM):
  laadpunten/wijzigingen/D.csv  tijd_utc,evse,status: een regel per statuswijziging (tijd = last_updated van het laadpunt;
                                evse = vaste code van 12 tekens, uit te zoeken in kenmerken)
  laadpunten/stand/D.csv.gz     status van elk laadpunt (wekelijks, op maandag): het beginpunt voor de wijzigingen
  laadpunten/kenmerken/D.csv.gz exploitant, adres, coordinaten, vermogen en stekkers per laadpunt (wekelijks, op maandag)
  parkeren/npr/D.csv            tijd_utc,garage_id,vrij,capaciteit,open,vol
  parkeren/amsterdam/D.csv      tijd_utc,locatie_id,naam,status,vrij_kort,capaciteit_kort,vrij_lang,capaciteit_lang
  parkeren/vrachtwagen/D.csv    tijd_utc,locatie_id,vrij,bezet,bezetting_pct
  parkeren/garages/D.csv        kenmerken van de NPR-garages met dynamische data (wekelijks, op maandag)
  parkeren/catalogus/D.csv      alle NPR-parkeerfaciliteiten (wekelijks, op maandag)
  runs/D.csv                    een regel per bron per run (dekking en fouten controleren)
  state/                        laatst bekende stand, nodig om wijzigingen te herkennen
(D = JJJJ-MM-DD, de UTC-datum van de run.)
"""
import csv
import gzip
import hashlib
import io
import json
import time
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
from pathlib import Path

UA = "realtime-verzamelaar/1.0 (+https://github.com/api28092026-cmyk/realtime-verzamelaar)"
DATA = Path("data")
NU = datetime.now(timezone.utc)
TS = NU.strftime("%Y-%m-%dT%H:%M:%SZ")
DAG = NU.strftime("%Y-%m-%d")

LAAD_URL = "https://opendata.ndw.nu/charging_point_locations_ocpi.json.gz"
NPR_URL = "https://npropendata.rdw.nl/parkingdata/v2"
AMS_URL = "https://p-info.vorin-amsterdam.nl/v1/ParkingLocation.json"
TRUCK_URL = "https://opendata.ndw.nu/Truckparking_Parking_Status.xml"
TRUCK_TABEL_URL = "https://opendata.ndw.nu/Truckparking_Parking_Table.xml"


# ---------- hulpfuncties ----------

def haal(url: str, timeout: int = 60, pogingen: int = 3) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
    for poging in range(1, pogingen + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception:
            if poging == pogingen:
                raise
            time.sleep(5 * poging)


def voeg_toe(pad: Path, kop: list, rijen: list) -> None:
    if not rijen:
        return
    pad.parent.mkdir(parents=True, exist_ok=True)
    nieuw = not pad.exists()
    with pad.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if nieuw:
            w.writerow(kop)
        w.writerows(rijen)


def schrijf(pad: Path, kop: list, rijen: list, gz: bool = False) -> None:
    pad.parent.mkdir(parents=True, exist_ok=True)
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(kop)
    w.writerows(rijen)
    data = buf.getvalue().encode("utf-8")
    pad.write_bytes(gzip.compress(data, 6) if gz else data)


def iso(waarde) -> str:
    """Bron-tijdstip naar JJJJ-MM-DDTHH:MM:SSZ; onbruikbaar (leeg, jaar 0001) wordt de runtijd."""
    if waarde is None or waarde == "":
        return TS
    try:
        if isinstance(waarde, (int, float)):
            t = datetime.fromtimestamp(waarde, timezone.utc)
        else:
            t = datetime.fromisoformat(str(waarde).replace("Z", "+00:00"))
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
        if t.year < 2000:
            return TS
        return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        return TS


def lees_json(pad: Path, standaard):
    try:
        return json.loads(pad.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return standaard


# ---------- laadpunten ----------

def laadpunten() -> tuple:
    locs = json.loads(gzip.decompress(haal(LAAD_URL, timeout=120)))
    nu = {}
    kenmerken = []
    for loc in locs:
        op = (loc.get("operator") or {}).get("name") or loc.get("party_id") or ""
        coord = loc.get("coordinates") or {}
        for e in loc.get("evses") or []:
            # Korte vaste code per laadpunt (12 tekens) in plaats van party|locatie|uid (~70 tekens); de koppeling staat in kenmerken.
            k = hashlib.sha1(f"{loc.get('party_id')}|{loc.get('id')}|{e.get('uid')}".encode()).hexdigest()[:12]
            lu = e.get("last_updated") or ""
            nu[k] = (lu, e.get("status") or "")
            conns = e.get("connectors") or []
            kw = max([(c.get("max_electric_power") or (c.get("max_voltage") or 0) * (c.get("max_amperage") or 0)) for c in conns] or [0]) / 1000
            kenmerken.append([k, loc.get("party_id"), loc.get("id"), e.get("uid") or "", e.get("evse_id") or "",
                              op, loc.get("name") or "", loc.get("address") or "", loc.get("postal_code") or "", loc.get("city") or "",
                              coord.get("latitude") or "", coord.get("longitude") or "",
                              int(any(str(c.get("power_type") or "").startswith("DC") for c in conns)), round(kw, 1),
                              " ".join(sorted({str(c.get("standard") or "") for c in conns}))])

    state_pad = DATA / "state" / "laadpunten.csv"
    oud = {}
    if state_pad.exists():
        with state_pad.open(encoding="utf-8", newline="") as f:
            for r in csv.reader(f):
                if len(r) == 3:
                    oud[r[0]] = (r[1], r[2])

    rijen = []
    if oud:
        for k, (lu, st) in nu.items():
            if oud.get(k) != (lu, st):
                rijen.append([iso(lu), k, st])
        rijen += [[TS, k, "VERDWENEN"] for k in oud.keys() - nu.keys()]
        rijen.sort()
        voeg_toe(DATA / "laadpunten" / "wijzigingen" / f"{DAG}.csv", ["tijd_utc", "evse", "status"], rijen)

    # Wekelijks (maandag, en bij een lege state) de volledige stand en de vaste kenmerken: het beginpunt om de wijzigingen op toe te passen.
    if not oud or (NU.weekday() == 0 and not (DATA / "laadpunten" / "stand" / f"{DAG}.csv.gz").exists()):
        schrijf(DATA / "laadpunten" / "stand" / f"{DAG}.csv.gz", ["evse", "status", "last_updated_utc"],
                sorted([k, st, iso(lu) if lu else ""] for k, (lu, st) in nu.items()), gz=True)
        schrijf(DATA / "laadpunten" / "kenmerken" / f"{DAG}.csv.gz",
                ["evse", "party_id", "locatie_id", "evse_uid", "evse_id", "exploitant", "naam", "adres", "postcode", "plaats",
                 "lat", "lon", "dc", "max_kw", "connectoren"], sorted(kenmerken, key=lambda r: [str(x) for x in r[1:4]]), gz=True)

    # Platte, gesorteerde tekst: git slaat per run alleen de gewijzigde regels op.
    state_pad.parent.mkdir(parents=True, exist_ok=True)
    with state_pad.open("w", encoding="utf-8", newline="") as f:
        csv.writer(f).writerows([k, lu, st] for k, (lu, st) in sorted(nu.items()))
    return len(nu), len(rijen)


# ---------- parkeren ----------

def npr(state: dict) -> tuple:
    s = state.setdefault("npr", {})
    garages = s.setdefault("garages", {})
    maandag = NU.weekday() == 0
    if s.get("catalogus_dag") != DAG or not garages:
        cat = json.loads(haal(NPR_URL, timeout=180)).get("ParkingFacilities") or []
        if maandag or not (DATA / "parkeren" / "catalogus").exists():
            schrijf(DATA / "parkeren" / "catalogus" / f"{DAG}.csv",
                    ["garage_id", "naam", "dynamisch", "beperkte_toegang", "statisch_bijgewerkt_utc"],
                    sorted([g.get("identifier"), g.get("name"), int(bool(g.get("dynamicDataUrl"))), int(bool(g.get("limitedAccess"))),
                            iso(g.get("staticDataLastUpdated")) if g.get("staticDataLastUpdated") else ""] for g in cat))
        dyn = {g["identifier"]: g for g in cat if g.get("dynamicDataUrl") and not g.get("limitedAccess") and g.get("identifier")}
        for gid in list(garages):
            if gid not in dyn:
                del garages[gid]
        for gid, g in dyn.items():
            garages.setdefault(gid, {})["url"] = g["dynamicDataUrl"]
            garages[gid]["static"] = g.get("staticDataUrl")
        if maandag or not (DATA / "parkeren" / "garages").exists():
            garage_kenmerken(dyn)
        s["catalogus_dag"] = DAG

    # Garages die al een dag niets bijwerken: alleen in de eerste run van elk uur proberen.
    grens = (NU - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    te_doen = [gid for gid, g in garages.items() if NU.minute < 5 or g.get("tijd", "9") >= grens]

    def een(gid):
        try:
            st = json.loads(haal(garages[gid]["url"], timeout=20, pogingen=2))["parkingFacilityDynamicInformation"]["facilityActualStatus"]
            return gid, st
        except Exception:
            return gid, None

    rijen, mislukt = [], 0
    with ThreadPoolExecutor(max_workers=6) as pool:
        for gid, st in pool.map(een, te_doen):
            if st is None:
                mislukt += 1
                continue
            rij = [iso(st.get("lastUpdated")), gid, st.get("vacantSpaces"), st.get("parkingCapacity"), int(bool(st.get("open"))), int(bool(st.get("full")))]
            g = garages[gid]
            if g.get("laatst") != rij[2:] or NU.minute < 5:   # bij wijziging, en elk uur alles (teken van leven)
                rijen.append(rij)
            g["laatst"], g["tijd"] = rij[2:], rij[0]
    rijen.sort()
    voeg_toe(DATA / "parkeren" / "npr" / f"{DAG}.csv", ["tijd_utc", "garage_id", "vrij", "capaciteit", "open", "vol"], rijen)
    if len(te_doen) and mislukt == len(te_doen):
        raise RuntimeError(f"alle {mislukt} garages mislukt")
    return len(te_doen) - mislukt, len(rijen)


def garage_kenmerken(dyn: dict) -> None:
    """Wekelijks: naam, exploitant, adres, coordinaten en capaciteit van de garages met dynamische data."""
    def een(g):
        try:
            return g, json.loads(haal(g["staticDataUrl"], timeout=20, pogingen=2))["parkingFacilityInformation"]
        except Exception:
            return g, None
    rijen = []
    with ThreadPoolExecutor(max_workers=6) as pool:
        for g, info in pool.map(een, [g for g in dyn.values() if g.get("staticDataUrl")]):
            if not info:
                continue
            spec = (info.get("specifications") or [{}])[-1]
            ap = (info.get("accessPoints") or [{}])[0]
            loc = (ap.get("accessPointLocation") or [{}])[0]
            adr = ap.get("accessPointAddress") or {}
            rijen.append([g["identifier"], info.get("name") or "", (info.get("operator") or {}).get("name") or "",
                          adr.get("streetName") or "", adr.get("houseNumber") or "", adr.get("zipcode") or "", adr.get("city") or "",
                          loc.get("latitude") or "", loc.get("longitude") or "", spec.get("capacity") or "",
                          spec.get("chargingPointCapacity") or "", spec.get("usage") or ""])
    schrijf(DATA / "parkeren" / "garages" / f"{DAG}.csv",
            ["garage_id", "naam", "exploitant", "straat", "huisnummer", "postcode", "plaats", "lat", "lon", "capaciteit",
             "laadplekken", "gebruik"], sorted(rijen))


def amsterdam(state: dict) -> tuple:
    s = state.setdefault("amsterdam", {})
    feats = json.loads(haal(AMS_URL, timeout=20, pogingen=2)).get("features") or []
    rijen = []
    for f in feats:
        p = f.get("properties") or {}
        lid = f.get("Id") or ""
        rij = [iso(p.get("PubDate")), lid, (p.get("Name") or "").strip(), p.get("State") or "", p.get("FreeSpaceShort") or "",
               p.get("ShortCapacity") or "", p.get("FreeSpaceLong") or "", p.get("LongCapacity") or ""]
        if s.get(lid) != rij[1:] or NU.minute < 5:      # bij wijziging, en elk uur alles (teken van leven)
            rijen.append(rij)
            s[lid] = rij[1:]
    rijen.sort()
    voeg_toe(DATA / "parkeren" / "amsterdam" / f"{DAG}.csv",
             ["tijd_utc", "locatie_id", "naam", "status", "vrij_kort", "capaciteit_kort", "vrij_lang", "capaciteit_lang"], rijen)
    return len(feats), len(rijen)


def vrachtwagen(state: dict) -> tuple:
    s = state.setdefault("vrachtwagen", {})
    root = ET.fromstring(haal(TRUCK_URL, timeout=20, pogingen=2))
    # Eerste afstammeling met deze naam (zonder namespace); het element zelf telt niet mee.
    lokaal = lambda el, naam: next((c for c in el.iter() if c is not el and c.tag.rsplit("}", 1)[-1] == naam), None)
    rijen, n = [], 0
    for rec in (el for el in root.iter() if el.tag.endswith("}parkingRecordStatus")):
        n += 1
        ref = lokaal(rec, "parkingRecordReference")
        bez = next((c for c in rec if c.tag.endswith("}parkingOccupancy")), None)
        waarde = lambda naam: (lokaal(bez, naam).text if bez is not None and lokaal(bez, naam) is not None else "")
        tijd = lokaal(rec, "parkingStatusOriginTime")
        lid = ref.get("id") if ref is not None else ""
        rij = [iso(tijd.text if tijd is not None else ""), lid, waarde("parkingNumberOfVacantSpaces"),
               waarde("parkingNumberOfOccupiedSpaces"), waarde("parkingOccupancy")]
        if s.get(lid) != rij[2:] or NU.minute < 5:      # bij wijziging, en elk uur alles (teken van leven)
            rijen.append(rij)
            s[lid] = rij[2:]
    rijen.sort()
    voeg_toe(DATA / "parkeren" / "vrachtwagen" / f"{DAG}.csv", ["tijd_utc", "locatie_id", "vrij", "bezet", "bezetting_pct"], rijen)
    if NU.weekday() == 0 and NU.hour == 0 and NU.minute < 5 or not (DATA / "parkeren" / "vrachtwagen_tabel.xml").exists():
        (DATA / "parkeren" / "vrachtwagen_tabel.xml").write_bytes(haal(TRUCK_TABEL_URL))
    return n, len(rijen)


# ---------- hoofdprogramma ----------

def main() -> None:
    state_pad = DATA / "state" / "parkeren.json"
    state = lees_json(state_pad, {})
    log = []
    for naam, functie in (("laadpunten", laadpunten), ("npr", lambda: npr(state)), ("amsterdam", lambda: amsterdam(state)),
                          ("vrachtwagen", lambda: vrachtwagen(state))):
        t0 = time.time()
        try:
            n, r = functie()
            log.append([TS, naam, "ok", n, r, round(time.time() - t0, 1), ""])
        except Exception as e:
            log.append([TS, naam, "fout", 0, 0, round(time.time() - t0, 1), f"{type(e).__name__}: {e}"[:200]])
    state_pad.parent.mkdir(parents=True, exist_ok=True)
    state_pad.write_text(json.dumps(state, sort_keys=True, indent=0), encoding="utf-8")
    voeg_toe(DATA / "runs" / f"{DAG}.csv", ["tijd_utc", "bron", "status", "items", "rijen", "duur_s", "fout"], log)
    for r in log:
        print(" ".join(str(x) for x in r))


if __name__ == "__main__":
    main()
