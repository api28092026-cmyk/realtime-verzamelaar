@{
    # Waar de verzamelde data komt te staan (relatief t.o.v. deze map, of een absoluut pad).
    DataDir        = 'data'

    # Neutrale, eerlijke identificatie richting de bronnen. Geen bedrijfsnaam nodig;
    # een algemeen contactadres is netjes maar optioneel, bv. 'realtime-verzamelaar/1.0 (+data@voorbeeld.nl)'.
    UserAgent      = 'realtime-verzamelaar/1.0'

    # Pauze tussen opeenvolgende verzoeken aan dezelfde bron (milliseconden).
    PauzeMs        = 700

    # Hoeveel dagen ruwe downloads (zip, gz, json) bewaard blijven. Aggregaten blijven altijd staan.
    BewaarRuwDagen = 30

    # TenderNed: maximaal aantal pagina's van 100 publicaties per run (de eerste run haalt zo ~1.000 terug;
    # daarna stopt hij vanzelf bij de eerste pagina zonder nieuwe publicaties).
    TenderNedMaxPaginas  = 10
    # Per nieuwe publicatie de detailpagina ophalen (CPV- en regiocodes). Kost ~1 verzoek per publicatie.
    TenderNedDetails     = $true

    # RDW: hoeveel dagen terug de nieuwe registraties opnieuw worden geteld (late registraties vangen).
    RdwDagenTerug  = 10

    # KVK open dataset: hoeveel dagen terug oprichtingen per aanvangsdatum worden bijgewerkt.
    KvkDagenTerug  = 60
}
