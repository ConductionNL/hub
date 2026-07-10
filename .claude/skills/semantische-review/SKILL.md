---
name: semantische-review
description: Periodieke semantische docs-review van een component — legt proza naast code/config en meldt tegenstrijdigheden. Gebruik bij "semantische review", "docs-review <component>", "klopt de documentatie van X nog".
---

# Semantische review

Cadans: maandelijks, twee componenten per beurt (roterend; volgorde =
langst niet gereviewd eerst, zie `last_reviewed` in de front-matter).
Dit vangt wat doc-assertions en verify-blokken níet kunnen: vrij proza.

## Werkwijze per component

1. Lees de docs via MCP `conduction-docs` (`list_components` →
   `read_page` per pagina); de lokale checkout is de code-kant.
2. Extraheer per pagina de **feitelijke beweringen** (paden, namen,
   defaults, flows, statusclaims — geen meningen/uitleg).
3. Toets elke bewering tegen de bron: manifests, scripts, configs,
   Makefiles. GET-check-first: lees écht, neem niets aan.
4. Classificeer: klopt / drift (bewering ≠ werkelijkheid) /
   ontoetsbaar-proza.
5. **Drift**: triviale gevallen direct fixen (docs-as-code, zelfde
   wijziging), structurele als bevinding melden via de
   docs-drift-routing (issue in handbook, label `docs-drift`) mét beide
   bronnen geciteerd.
6. Sluit af met: aantal beweringen getoetst / drift gevonden / gefixt,
   en bump `last_reviewed` van de gereviewde pagina's — de review ís
   de handeling.
7. Kandidaat-promotie: elke getoetste bewering die zich leent voor een
   doc-assertion of verify-blok → voorstel in dezelfde wijziging
   (semantisch werk hoort te slinken naarmate lagen 1-2 groeien).
