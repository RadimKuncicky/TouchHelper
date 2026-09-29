## Pravidla

- Respektuješ pravidla z globálního `AGENTS.md`.
- Hlavní agent řídí workflow, deleguje práci a odpovídá za finální výsledek.
- Subagenti mají řešit pouze svou přidělenou část úlohy.
- Kód může měnit pouze agent `implementer`.

## Analýza požadavku

Před zahájením netriviální práce použij agenta `request-analyzer`.

`request-analyzer`:
- analyzuje původní požadavek uživatele,
- oddělí explicitní požadavky, předpoklady a nejasnosti,
- vytvoří acceptance criteria,
- určí, které nejasnosti lze zjistit z repozitáře a které vyžadují uživatele,
- doporučí potřebné fáze workflow,
- nesmí implementovat změny ani provádět průzkum repozitáře.

Pokud `request-analyzer` vrátí `blocking_questions`, které nelze bezpečně vyřešit průzkumem repozitáře ani rozumným nízkorizikovým předpokladem, polož uživateli pouze tyto otázky a před implementací vyčkej na odpověď.

Nezastavuj workflow kvůli nejasnostem, které:
- může vyřešit `explorer`,
- lze zjistit z existujícího kódu,
- lze bezpečně pokrýt rozumným předpokladem bez významného dopadu na výsledek.

Pro malý, jasný a jednoznačný požadavek není nutné `request-analyzer` spouštět.

Výstup `request-analyzer` používej jako pracovní `task contract`. Neprováděj bez důvodu druhou kompletní analýzu stejného zadání.

## Delegování práce

U netriviálních úloh nejdřív vyhodnoť, zda se dají bezpečně rozdělit.

- Pro analýzu nebo zpřesnění netriviálního požadavku použij `request-analyzer`.
- Pro průzkum neznámého kódu použij `explorer`.
- Pro netriviální změny ovlivňující GUI nebo uživatelský tok použij před implementací `gui-ux-designer`.
- Pro změny s reálným rizikem regrese použij `reviewer`.
- Kód může měnit pouze `implementer`.
- Pro malé a jasné opravy volej přímo `implementer`; nevolej předem `request-analyzer`, `explorer`, `gui-ux-designer` ani dedikovaného `reviewer`, pokud pro ně není konkrétní důvod.
- Každá změna musí projít alespoň základním review hlavního agenta.
- `reviewer` použij zejména pro změny s reálným rizikem regrese, bezpečnostním dopadem, změnou veřejného API, změnou datového modelu nebo větším rozsahem.
- Nespouštěj subagenta pouze proto, že je dostupný. Každé delegování musí mít konkrétní účel.

## Fáze workflow

Typické workflow pro netriviální úlohu:

```text
request-analyzer
      ↓
blocking questions?
   ├─ ano → uživatel
   └─ ne
       ↓
    explorer
       ↓
gui-ux-designer
  (pokud relevantní)
       ↓
  implementer
       ↓
     testy
       ↓
basic review hlavního agenta
       ↓
významné riziko?
   ├─ ano → reviewer
   │           ↓
   │      případná oprava
   │           ↓
   │         testy
   └─ ne
       ↓
     výstup
```

Jednotlivé fáze vynechávej, pokud pro danou úlohu nemají konkrétní přínos.

### Před implementací

1. `request-analyzer` — pouze pokud je požadavek netriviální, nejasný nebo má více možných interpretací.
2. `explorer` — pokud je nutné zjistit existující implementaci, závislosti nebo dopady změny.
3. `gui-ux-designer` — pokud změna netriviálně ovlivňuje GUI, UX nebo uživatelský tok.

### Implementace

- `implementer`

Implementer dostane:
- původní požadavek,
- relevantní `task contract` z `request-analyzer`,
- relevantní závěry `explorer`,
- návrh `gui-ux-designer`, pokud existuje.

Nepředávej mu zbytečný celý výstup ostatních agentů, pokud není pro implementaci relevantní.

### Po implementaci

1. Spusť relevantní testy a validace.
2. Proveď základní review hlavním agentem.
3. Pokud změna představuje významné riziko, použij `reviewer`.
4. Pokud review objeví problém, předej konkrétní findings zpět `implementer`.
5. Po opravě spusť relevantní testy znovu.
6. Vrať uživateli stručný výsledek včetně podstatných změn, validace a případných otevřených rizik.

## Komunikace mezi agenty

Preferuj předávání stručných strukturovaných výsledků před volnou diskusí mezi agenty.

Agent může požádat jiného agenta o doplnění pouze tehdy, pokud mu chybí konkrétní informace potřebná k dokončení jeho úkolu.

Typické směry komunikace:

```text
request-analyzer → orchestrator

explorer → orchestrator
gui-ux-designer → orchestrator

orchestrator → implementer

reviewer → orchestrator
orchestrator → implementer
```

Pokud lze otázku vyřešit orchestrátorem z již dostupných výsledků, nespouštěj kvůli ní dalšího agenta.

Zabraň cyklickému předávání úloh mezi agenty.

## Handoff report subagentů

Každý spuštěný subagent musí na konci výstupu přidat stručný `HANDOFF REPORT`.

Report musí obsahovat:

- `Scope:` co skutečně analyzoval nebo měnil.
- `Inspected/Changed:` hlavní soubory, komponenty nebo symboly.
- `Result:` hlavní výsledek práce.
- `Validation:` co bylo ověřeno nebo spuštěno.
- `Open:` nevyřešená rizika, nejistoty nebo blokery.
- `Next:` doporučený další krok.

Report drž stručný, typicky 5–10 řádků.

Uváděj provedené kroky a ověřitelné závěry, ne interní reasoning.

Pokud některá položka není relevantní, použij například:

```text
Open: none
```

### Request Analyzer handoff

U `request-analyzer` může být `HANDOFF REPORT` ještě stručnější, protože hlavním výstupem je jeho strukturovaný task contract.

Například:

```text
HANDOFF REPORT
Scope: Analyzed user request and converted it into a task contract.
Inspected/Changed: User request only; no repository access.
Result: Request is sufficiently specified for implementation.
Validation: Checked for blocking ambiguities and missing requirements.
Open: none
Next: Continue with explorer.
```