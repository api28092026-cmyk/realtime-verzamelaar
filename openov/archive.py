#!/usr/bin/env python3
"""
Archiveert afgesloten maanden uit data/. Alleen standaardbibliotheek.

  archive.py pack          zipt elke afgesloten maand (changes + scrapes + locaties_meta)
                           naar archive/ovfiets_YYYY-MM.zip en drukt de maanden af
  archive.py mail M ...    mailt de zips, als de SMTP_*-variabelen gezet zijn (anders overslaan)
  archive.py prune M ...   verwijdert de maandbestanden uit data/

De workflow zet de zips in een GitHub Release (data-YYYY-MM) voordat er iets wordt verwijderd.

Mail-variabelen (GitHub secrets): SMTP_HOST, SMTP_PORT (587), SMTP_USER, SMTP_PASSWORD, MAIL_TO
(meerdere adressen met komma's), optioneel MAIL_FROM (standaard SMTP_USER).
"""
import os
import smtplib
import sys
import zipfile
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path

DATA = Path("data")
OUT = Path("archive")
MAX_ATTACHMENT = 15 * 1024 * 1024   # grotere zips alleen als link mailen (mailservers weigeren ~20-25 MB)


def month_files(month: str) -> list:
    return [DATA / "changes" / f"{month}.csv", DATA / "scrapes" / f"{month}.csv"]


def closed_months() -> list:
    current = f"{datetime.now(timezone.utc):%Y-%m}"
    months = {p.stem for sub in ("changes", "scrapes") for p in (DATA / sub).glob("*.csv")}
    return sorted(m for m in months if m < current)


def pack() -> None:
    months = closed_months()
    OUT.mkdir(exist_ok=True)
    for m in months:
        with zipfile.ZipFile(OUT / f"ovfiets_{m}.zip", "w", zipfile.ZIP_DEFLATED) as z:
            for p in month_files(m) + [DATA / "locaties_meta.csv"]:
                if p.exists():
                    z.write(p, p.relative_to(DATA).as_posix())
    print(" ".join(months))


def mail(months: list) -> None:
    host = os.environ.get("SMTP_HOST")
    if not host or not months:
        print("Geen SMTP_HOST ingesteld of niets te mailen, mail overgeslagen.")
        return
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    msg = EmailMessage()
    msg["Subject"] = f"OV-fiets data {', '.join(months)}"
    msg["From"] = os.environ.get("MAIL_FROM") or os.environ["SMTP_USER"]
    msg["To"] = os.environ["MAIL_TO"]
    lines = ["In de bijlage de OV-fiets data van de afgesloten maand(en).", ""]
    for m in months:
        zp = OUT / f"ovfiets_{m}.zip"
        link = f"https://github.com/{repo}/releases/tag/data-{m}"
        if zp.stat().st_size <= MAX_ATTACHMENT:
            msg.add_attachment(zp.read_bytes(), maintype="application", subtype="zip", filename=zp.name)
            lines.append(f"{m}: bijgevoegd ({zp.stat().st_size / 1e6:.1f} MB), ook te downloaden via {link}")
        else:
            lines.append(f"{m}: te groot om bij te voegen ({zp.stat().st_size / 1e6:.1f} MB), download via {link}")
    msg.set_content("\n".join(lines))
    with smtplib.SMTP(host, int(os.environ.get("SMTP_PORT") or 587), timeout=60) as s:
        s.starttls()
        s.login(os.environ["SMTP_USER"], os.environ["SMTP_PASSWORD"])
        s.send_message(msg)
    print(f"Gemaild naar {msg['To']}.")


def prune(months: list) -> None:
    for m in months:
        for p in month_files(m):
            p.unlink(missing_ok=True)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"pack": lambda: pack(), "mail": lambda: mail(args), "prune": lambda: prune(args)}[cmd]()
