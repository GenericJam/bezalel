"""Sanity-check the built packs: row counts, known lookups, the similar-passages
tables, ATTACH of every pack together, the theological scholarship and textual
variants, and that the deleted full texts did not ship.

  python check_packs.py --packs packs.json --exclusions exclusions.json \
      --fingerprints FINGERPRINTS.json --out OUT

Prints one line per check and exits non-zero if any fails.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import unicodedata
from pathlib import Path

# Floors well under the pinned build's counts: a broken import shows as a collapse.
MIN_ROWS = {
    "verses": 31_000, "bsb_verses": 31_000, "passages": 5_000, "lexicon": 19_000,
    "morphology": 2_000, "names": 4_000, "acai_entities": 5_000,
    "cross_references": 300_000, "thematic_references": 20,
    "torah_weave_units": 80, "torah_weave_cells": 900,
    "similar_verses": 600_000, "similar_passages": 600_000,
    "aquifer_content": 90_000, "ane_entries": 115, "ane_book_mappings": 400,
    "theology_content": 180, "theology_verse_index": 1000, "theology_themes": 60,
    "biblical_version_verses": 25_000,
    "ancient_source_passages": 20_000, "ancient_source_passages_fts": 20_000,
    "ancient_source_biblical_links": 5_000,
    "graph_people": 3_000, "graph_places": 1_000, "graph_events": 400,
    "graph_verse_mentions": 40_000, "graph_family_edges": 4_000,
}

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
    if not ok:
        failures.append(label)


def bare(text: str) -> str:
    """Hebrew/Greek without points, accents or cantillation."""
    return "".join(c for c in unicodedata.normalize("NFD", text) if not unicodedata.combining(c))


def strongs_in(word_data: str) -> set[str]:
    return {re.sub(r"[A-Z]$", "", w["strongs"]) for w in json.loads(word_data) if w.get("strongs")}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packs", type=Path, required=True)
    parser.add_argument("--exclusions", type=Path, required=True)
    parser.add_argument("--fingerprints", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    packs = json.loads(args.packs.read_text())["packs"]
    exclusions = json.loads(args.exclusions.read_text())

    # Every pack opens on its own with exactly its tables.
    for name, spec in packs.items():
        conn = sqlite3.connect(f"file:{args.out / (name + '.sqlite')}?mode=ro", uri=True)
        tables = {
            r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
                "AND name NOT LIKE '%_fts_%'"
            )
        }
        check(f"{name}: tables", tables == set(spec["tables"]) | {"pack_meta"},
              f"{sorted(tables ^ (set(spec['tables']) | {'pack_meta'}))}" if tables != set(spec["tables"]) | {"pack_meta"} else "")
        for table in spec["tables"]:
            count = conn.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            floor = MIN_ROWS.get(table, 1)
            check(f"{name}.{table}", count >= floor, f"{count} rows (floor {floor})")
        conn.close()

    # All packs attached to one connection, as the app may use them.
    db = sqlite3.connect("file::memory:", uri=True)
    for name in packs:
        db.execute("ATTACH DATABASE ? AS " + name, (f"file:{args.out / (name + '.sqlite')}?mode=ro",))
    one = lambda sql, *p: db.execute(sql, p).fetchone()  # noqa: E731

    # Exodus 31:2-3, Bezalel.
    v2 = one("SELECT text_original, word_data FROM verses WHERE reference = 'Exo.31.2'")
    v3 = one("SELECT text_original, word_data FROM verses WHERE reference = 'Exo.31.3'")
    check("Exo 31:2 Hebrew names Bezalel (בצלאל, H1212)",
          v2 is not None and "בצלאל" in bare(v2[0]) and "H1212" in strongs_in(v2[1]))
    check("Exo 31:3 Hebrew has רוח H7307, חכמה H2451, מלא H4390",
          v3 is not None and {"H7307", "H2451", "H4390"} <= strongs_in(v3[1])
          and all(w in bare(v3[0]) for w in ("רוח", "חכמה")))
    b2 = one("SELECT text FROM bsb_verses WHERE reference = 'Exo.31.2'")
    b3 = one("SELECT text FROM bsb_verses WHERE reference = 'Exo.31.3'")
    check("BSB Exo 31:2", b2 is not None and "Bezalel son of Uri" in b2[0], b2[0] if b2 else "missing")
    check("BSB Exo 31:3", b3 is not None and "Spirit of God" in b3[0], b3[0] if b3 else "missing")
    for strongs, gloss in (("H7307", "spirit"), ("H2451", "wisdom"), ("H4390", "fill")):
        row = one("SELECT word, short_definition, full_definition FROM lexicon WHERE strongs = ?", strongs)
        text = " ".join(filter(None, row[1:])).lower() if row else ""
        check(f"lexicon {strongs} ({gloss})", gloss in text, f"{row[0]} {row[1]}" if row else "missing")
    row = one("SELECT word, short_definition FROM lexicon WHERE strongs = 'G4151'")
    check("lexicon G4151 (πνεῦμα)", row is not None and "πνεῦμα" in row[0], str(row))
    check("names: Bezalel", one("SELECT COUNT(*) FROM names WHERE name LIKE 'Bezalel%'")[0] > 0)
    check("morphology: V-AAI-3S",
          one("SELECT parsing FROM morphology WHERE code = 'V-AAI-3S'") is not None)
    check("cross references from Gen 1:1",
          one("SELECT COUNT(*) FROM cross_references WHERE source = 'Gen.1.1'")[0] > 10)

    # Similar passages: every verse with text has k neighbours; known parallels rank high.
    def neighbours(ref: str, table: str = "similar_verses") -> list[str]:
        join = ("JOIN verses n ON n.id = s.similar_verse_id" if table == "similar_verses"
                else "JOIN passages n ON n.id = s.passage_id")
        col = "n.reference" if table == "similar_verses" else "n.reference_start"
        return [r[0] for r in db.execute(
            f"SELECT {col} FROM {table} s JOIN verses v ON v.id = s.verse_id {join} "
            "WHERE v.reference = ? OR v.reference LIKE ? ORDER BY s.rank", (ref, ref + "(%"))]

    with_text = {r[0] for r in db.execute(
        "SELECT id FROM verses WHERE trim(coalesce(text_english, '')) != ''")}
    all_verses = {r[0] for r in db.execute("SELECT id FROM verses")}
    print(f"  verses with text (and so with similarity rows): {len(with_text)} of {len(all_verses)}")
    for table, target, target_table in (("similar_verses", "similar_verse_id", "verses"),
                                        ("similar_passages", "passage_id", "passages")):
        per_verse = one(f"SELECT MIN(c), MAX(c), COUNT(*) FROM (SELECT COUNT(*) c FROM {table} GROUP BY verse_id)")
        check(f"{table}: 20 neighbours per verse", per_verse[0] == per_verse[1] == 20,
              f"{per_verse[2]} verses, {per_verse[0]}-{per_verse[1]} each")
        sources = {r[0] for r in db.execute(f"SELECT DISTINCT verse_id FROM {table}")}
        check(f"{table}: every verse with text has rows", with_text <= sources,
              f"{len(with_text - sources)} missing")
        check(f"{table}: every source is a verse", sources <= all_verses)
        dangling = one(f"SELECT COUNT(*) FROM {table} s LEFT JOIN {target_table} t ON t.id = s.{target} "
                       "WHERE t.id IS NULL")[0]
        check(f"{table}: every target exists", dangling == 0, f"{dangling} dangling")
        bad = one(f"SELECT COUNT(*) FROM {table} WHERE similarity_permille NOT BETWEEN -1000 AND 1000")[0]
        check(f"{table}: scores in range", bad == 0)
        unordered = one(f"SELECT COUNT(*) FROM {table} a JOIN {table} b ON b.verse_id = a.verse_id "
                        "AND b.rank = a.rank + 1 WHERE b.similarity_permille > a.similarity_permille")[0]
        check(f"{table}: ranks ordered by score", unordered == 0)
    for source, expected in (("Exo.31.3", "Exo.35.31"), ("Deu.6.5", "Mrk.12.30"), ("Psa.22.18", "Jhn.19.24")):
        top = neighbours(source)[:5]
        check(f"similar to {source} includes {expected}", expected in top, ", ".join(top))
    contained = one(
        "SELECT COUNT(*) FROM similar_passages s JOIN passages p ON p.id = s.passage_id "
        "WHERE s.verse_id BETWEEN p.start_verse_id AND p.end_verse_id")[0]
    check("similar_passages never returns the verse's own passage", contained == 0)
    check("similar_verses never returns the verse itself",
          one("SELECT COUNT(*) FROM similar_verses WHERE verse_id = similar_verse_id")[0] == 0)

    # Optional packs.
    check("notes: Tyndale study note on Exodus 31",
          one("SELECT COUNT(*) FROM aquifer_content WHERE resource_type = 'study_notes' "
              "AND book_num = 2 AND chapter_start = 31")[0] > 0)
    for resource in ("study_notes", "dictionary", "translation_notes_uw", "translation_notes_sil", "key_terms"):
        check(f"aquifer {resource}",
              one("SELECT COUNT(*) FROM aquifer_content WHERE resource_type = ?", resource)[0] > 0)
    check("lxx: Genesis 1:1 has ἐν ἀρχῇ",
          any("εν αρχη" in bare(r[0] or "").lower() for r in db.execute(
              "SELECT text FROM biblical_version_verses WHERE canonical_book = 'Gen' "
              "AND canonical_chapter = 1 AND canonical_verse = 1")))
    check("ancient: full-text search finds Bezalel (Josephus/Philo)",
          one("SELECT COUNT(*) FROM ancient_source_passages_fts WHERE ancient_source_passages_fts MATCH 'Beseleel OR Bezalel OR Bezaleel'")[0] > 0)
    check("graph: people in Exodus 31",
          one("SELECT COUNT(*) FROM graph_verse_mentions WHERE verse_ref LIKE 'Exod.31.%' OR verse_ref LIKE 'Exo.31.%'")[0] > 0)

    # Theological scholarship: the authors included by decision are present, Burnett
    # (whose sources the repository lacks) is not, and the theme index is whole.
    authors = {r[0] for r in db.execute("SELECT DISTINCT source_author FROM theology_content")}
    check("theology: every included author present", set(exclusions["authors"]) <= authors,
          f"authors {sorted(authors)}")
    check("theology: absent authors not present", not (authors & set(exclusions["absent_authors"])))
    orphans = sorted({r[0] for r in db.execute(
        "SELECT DISTINCT i.theme_key FROM theology_theme_index i "
        "LEFT JOIN theology_themes t ON t.theme_key = i.theme_key WHERE t.theme_key IS NULL")})
    check("theology: every linked theme is defined", not orphans, str(orphans))
    check("ane: Lamb of the Free entries present (relig_012, method_008)",
          one("SELECT COUNT(*) FROM ane_entries WHERE id IN ('relig_012', 'method_008')")[0] == 2)

    # Textual variants (Heiser's dataset), as get_textual_variant reads them.
    for table, floor in (("textual_variant_cases", 25), ("textual_variant_readings", 30),
                         ("textual_variant_witnesses", 50), ("textual_author_claims", 10),
                         ("textual_translation_decisions", 10), ("nt_ot_lxx_quote_hints", 15)):
        count = one(f"SELECT COUNT(*) FROM {table}")[0]
        check(f"textual: {table}", count >= floor, f"{count} rows (floor {floor})")
    check("textual: Deuteronomy 32:8 case with an MT reading and witnesses",
          one("SELECT COUNT(*) FROM textual_variant_cases c "
              "JOIN textual_variant_readings r ON r.case_id = c.id AND r.reading_key = 'mt' "
              "JOIN textual_variant_witnesses w ON w.case_id = c.id WHERE c.reference = 'Deu.32.8'")[0] > 0)
    linked = one("SELECT COUNT(*) FROM nt_ot_lxx_quote_hints h LEFT JOIN textual_variant_cases c "
                 "ON c.id = h.variant_case_id WHERE h.variant_case_id IS NOT NULL AND c.id IS NULL")[0]
    check("textual: every quotation hint's case exists", linked == 0, f"{linked} dangling")

    # The deleted full texts did not ship: no deleted file has more than the threshold
    # of its fingerprint windows anywhere in the notes pack's text (short quotations
    # in a summary are expected). The Aquifer table is upstream CC text, not searched.
    text = []
    for table, columns in (
        (t, [c[1] for c in db.execute(f'PRAGMA notes.table_info("{t}")') if c[2] in ("TEXT", "")])
        for t in packs["notes"]["tables"] if t != "aquifer_content"
    ):
        for row in db.execute(f'SELECT {", ".join(columns)} FROM notes."{table}"'):
            text.extend(str(v) for v in row if v)
    haystack = " " + " ".join(re.sub(r"[^\w]+", " ", t.lower()) for t in text) + " "
    haystack = re.sub(r"\s+", " ", haystack)
    fingerprints = json.loads(args.fingerprints.read_text())
    coverage = {
        name: sum(f" {w} " in haystack for w in windows) / len(windows)
        for name, windows in fingerprints.items() if windows
    }
    worst = max(coverage, key=coverage.get)
    threshold = exclusions["full_text_threshold"]
    check(f"no deleted full text shipped ({len(coverage)} files, threshold {threshold:.0%})",
          coverage[worst] <= threshold, f"highest {worst}: {coverage[worst]:.0%}")
    marker = "Institute for Biblical Research"
    leaked = [t for t, c in (("theology_content", "content_summary"), ("theology_content", "content_detail"),
                             ("ane_entries", "detail"), ("aquifer_content", "content_plain"))
              if one(f"SELECT COUNT(*) FROM {t} WHERE {c} LIKE ?", f"%{marker}%")[0]]
    check("no 'Copyright 2008 The Institute for Biblical Research' text", not leaked, str(leaked))
    check("cross_references: only the openbible.info (TSK) set",
          {r[0] for r in db.execute("SELECT DISTINCT type FROM cross_references")} == {"tsk"})

    if failures:
        sys.exit(f"\n{len(failures)} check(s) failed")
    print("\nAll checks passed")


if __name__ == "__main__":
    main()
