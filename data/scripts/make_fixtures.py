"""Cut the small test packs from the built packs.

  python3 data/scripts/make_fixtures.py [--packs data/out] [--out test/fixtures/packs]

Each fixture is a pack file with the same tables, schemas and indexes as the
real pack (data/out/<pack>.sqlite), holding only the rows around a few
passages: Genesis 1-2, Exodus 31, Psalm 22, John 3 and Jude. Rows keep their
ids, so references between tables (similar_passages -> passages -> verses)
stay valid. What each table keeps:

core      the verses of those chapters, the BSB text of every kept verse, the
          lexicon entries the words of Exodus 31 cite plus the entries the
          tests read or search for, the morphology codes those chapters use
          plus the tests' codes, the names first mentioned there (and the
          tests' names) with their ACAI entities, the cross references from
          those verses, all thematic references, the Torah weave units over
          those chapters, and the nearest similar passages of a few anchor
          verses with the verses each passage's preview shows
graph     the verse mentions in those chapters and the people, places and
          events they name, with the edges among them
notes     the study notes, dictionary and translator notes over Exodus 31 and
          John 3, the ANE entries mapped to them, all theology themes and the
          theology content indexed to them
lxx       the Septuagint rows of those chapters
ancient   the ancient-source passages linked to those chapters, with their
          links, notes and search-index rows

The lexicon (BDB and LSJ definitions run to several KB an entry) and the
notes are the large tables, hence the narrower cut there. Run this after a
pack rebuild changes the data the tests read. Reads data/out read-only;
needs only the Python standard library.
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

FTS5_SHADOWS = ("_data", "_idx", "_content", "_docsize", "_config")

# (book code, Theographic book, chapter, book number)
CHAPTERS = [
    ("Gen", "Gen", 1, 1),
    ("Gen", "Gen", 2, 1),
    ("Exo", "Exod", 31, 2),
    ("Psa", "Ps", 22, 19),
    ("Jhn", "John", 3, 43),
    ("Jud", "Jude", 1, 65),
]
# The chapters whose notes are kept (the notes pack is mostly long articles).
NOTES_CHAPTERS = [c for c in CHAPTERS if c[0] in ("Exo", "Jhn")]
# The chapter whose words' lexicon entries are kept.
LEXICON_CHAPTER = ("Exo", 31)
# Verses whose similar passages are kept (the nearest SIMILAR_RANKS).
ANCHORS = ["Exo.31.3", "Psa.22.18(22.19)", "Jhn.3.16"]
SIMILAR_RANKS = 5
# Lexicon searches the tests run (search_lexicon, word_study by word): the
# first LEXICON_HITS entries the full lexicon ranks for each, in each
# language and in both, so the fixture returns what the real pack does for
# limits up to that.
LEXICON_QUERIES = ["wisdom", "love", "craftsman"]
LEXICON_HITS = 10
# Extra lexicon entries the tests read by number.
LEXICON_EXTRA = ["G0025", "G0026", "G4151", "H0157", "H7307"]
# Morphology codes the tests parse.
MORPHOLOGY_EXTRA = ["V-AAI-3S", "N-GSF", "V-PAI-3S", "HVqp3ms"]
# Names the tests look up besides those first mentioned in the chapters.
NAME_QUERIES = ["Bezalel", "Ai", "Judah", "David", "Uri"]
# A passage preview shows at most this many verses (PASSAGE_PREVIEW_VERSES).
PREVIEW_VERSES = 30


def chapter_clause(book_col: str, chapter_col: str, books=lambda c: c[0], chapters=CHAPTERS) -> str:
    return "(" + " OR ".join(
        f"({book_col} = '{books(c)}' AND {chapter_col} = {c[2]})" for c in chapters
    ) + ")"


def range_clause(book_col: str, start_col: str, end_col: str, books=lambda c: c[0], chapters=CHAPTERS) -> str:
    """Rows whose chapter span [start, end] covers one of the chapters."""
    return "(" + " OR ".join(
        f"({book_col} = '{books(c)}' AND {start_col} <= {c[2]} AND {end_col} >= {c[2]})"
        for c in chapters
    ) + ")"


def sort_clause(book_col: str, start_col: str, end_col: str) -> str:
    """Rows whose chapter*1000+verse span overlaps one of the chapters."""
    return "(" + " OR ".join(
        f"({book_col} = '{c[0]}' AND {start_col} <= {c[2] * 1000 + 999} AND {end_col} >= {c[2] * 1000})"
        for c in CHAPTERS
    ) + ")"


def like_any(column: str, patterns: list[str]) -> str:
    return "(" + " OR ".join(f"{column} LIKE '{p}'" for p in patterns) + ")"


def ids(conn: sqlite3.Connection, sql: str) -> list:
    return [row[0] for row in conn.execute(sql)]


def in_list(values) -> str:
    quoted = []
    for value in sorted(set(values), key=str):
        quoted.append(str(value) if isinstance(value, int) else "'" + str(value).replace("'", "''") + "'")
    return "(" + (", ".join(quoted) or "NULL") + ")"


def lexicon_hits(src: sqlite3.Connection, query: str, language: str | None) -> list[str]:
    """The entries search_lexicon ranks first for ``query`` (Bezalel.Study.Lexicon.search/3)."""
    like = f"%{query.lower()}%"
    columns = ("short_definition", "full_definition", "transliteration", "word", "abbott_smith_def")
    sql = "SELECT strongs FROM lexicon WHERE (" + " OR ".join(f"LOWER({c}) LIKE ?" for c in columns) + ")"
    params = [like] * len(columns)
    if language:
        sql += " AND language = ?"
        params.append(language)
    sql += """ ORDER BY CASE WHEN LOWER(short_definition) LIKE ? OR LOWER(word) LIKE ?
                              OR LOWER(transliteration) LIKE ? THEN 0 ELSE 1 END,
                    usage_count DESC, strongs LIMIT ?"""
    params += [like, like, like, LEXICON_HITS]
    return [row[0] for row in src.execute(sql, params)]


def core_filters(src: sqlite3.Connection) -> dict[str, str]:
    main = ids(src, f"SELECT id FROM verses WHERE {chapter_clause('book', 'chapter')}")
    anchors = ids(src, f"SELECT id FROM verses WHERE reference IN {in_list(ANCHORS)}")
    if len(anchors) != len(ANCHORS):
        sys.exit(f"anchor verses missing: {ANCHORS}")
    passages = ids(
        src,
        f"SELECT passage_id FROM similar_passages WHERE verse_id IN {in_list(anchors)} AND rank <= {SIMILAR_RANKS}",
    )
    preview = []
    for start, end in src.execute(
        f"SELECT start_verse_id, end_verse_id FROM passages WHERE id IN {in_list(passages)}"
    ):
        preview += ids(src, f"SELECT id FROM verses WHERE id BETWEEN {start} AND {end} ORDER BY id LIMIT {PREVIEW_VERSES}")
    verses = sorted(set(main) | set(preview))

    # Entries the words of one chapter cite (lookup_verse needs none: the
    # words carry their glosses), and the ones the tests read or search for.
    numbers = set(LEXICON_EXTRA)
    morphs = set(MORPHOLOGY_EXTRA)
    for book, chapter, word_data in src.execute(
        f"SELECT book, chapter, word_data FROM verses WHERE id IN {in_list(main)}"
    ):
        if (book, chapter) == LEXICON_CHAPTER:
            numbers.update(f"{m[0]}{int(m[1]):04d}" for m in re.findall(r"([GH])(\d{1,4})", word_data or ""))
        morphs.update(m for m in re.findall(r'"morph": "([^"]+)"', word_data or ""))
    for query in LEXICON_QUERIES:
        for language in (None, "greek", "hebrew"):
            numbers.update(lexicon_hits(src, query, language))

    refs_in_chapters = like_any("j.value", [f"{c[0]}.{c[2]}.%" for c in CHAPTERS])
    names = ids(
        src,
        f"""SELECT DISTINCT n.id FROM names n, json_each(n.refs) j WHERE {refs_in_chapters}
            UNION SELECT id FROM names WHERE {like_any('name', [f'%{q}%' for q in NAME_QUERIES])}""",
    )
    tipnr_keys = [
        f"{name}@{first}"
        for name, first in src.execute(
            f"SELECT name, json_extract(refs, '$[0]') FROM names WHERE id IN {in_list(names)}"
        )
        if first
    ]
    xref_sources = like_any("source", [f"{c[0]}.{c[2]}.%" for c in CHAPTERS])
    units = ids(
        src,
        f"SELECT DISTINCT unit_id FROM torah_weave_cells WHERE "
        + range_clause("book", "chapter_start", "chapter_end"),
    )
    return {
        "verses": f"id IN {in_list(verses)}",
        "bsb_verses": f"EXISTS (SELECT 1 FROM src.verses v WHERE v.id IN {in_list(verses)} "
        "AND v.book = bsb_verses.book AND v.chapter = bsb_verses.chapter AND v.verse = bsb_verses.verse)",
        "passages": f"id IN {in_list(passages)}",
        "lexicon": f"strongs IN {in_list(numbers)}",
        "morphology": f"code IN {in_list(morphs)}",
        "names": f"id IN {in_list(names)}",
        "acai_entities": f"EXISTS (SELECT 1 FROM json_each(acai_entities.tipnr_keys) k WHERE k.value IN {in_list(tipnr_keys)})",
        "cross_references": xref_sources,
        "thematic_references": "1",
        "torah_weave_units": f"id IN {in_list(units)}",
        "torah_weave_cells": f"unit_id IN {in_list(units)}",
        "similar_verses": "0",
        "similar_passages": f"verse_id IN {in_list(anchors)} AND rank <= {SIMILAR_RANKS}",
    }


def graph_filters(src: sqlite3.Connection) -> dict[str, str]:
    mentions = like_any("verse_ref", [f"{c[1]}.{c[2]}.%" for c in CHAPTERS])
    rows = src.execute(f"SELECT DISTINCT entity_type, entity_id FROM graph_verse_mentions WHERE {mentions}").fetchall()
    people = [i for t, i in rows if t == "person"]
    places = [i for t, i in rows if t == "place"]
    events = [i for t, i in rows if t == "event"]
    return {
        "graph_people": f"id IN {in_list(people)}",
        "graph_places": f"id IN {in_list(places)}",
        "graph_events": f"id IN {in_list(events)}",
        "graph_people_groups": f"name IN (SELECT group_name FROM src.graph_person_group_edges WHERE person_id IN {in_list(people)})",
        "graph_family_edges": f"from_person_id IN {in_list(people)} AND to_person_id IN {in_list(people)}",
        "graph_person_event_edges": f"person_id IN {in_list(people)} AND event_id IN {in_list(events)}",
        "graph_event_place_edges": f"event_id IN {in_list(events)} AND place_id IN {in_list(places)}",
        "graph_person_group_edges": f"person_id IN {in_list(people)}",
        "graph_verse_mentions": mentions,
    }


def notes_filters(src: sqlite3.Connection) -> dict[str, str]:
    entries = ids(
        src,
        "SELECT DISTINCT entry_id FROM ane_book_mappings WHERE "
        + " OR ".join(
            f"(book = '{c[0]}' AND (chapter_start IS NULL OR (chapter_start <= {c[2]} "
            f"AND COALESCE(chapter_end, chapter_start) >= {c[2]})))"
            for c in NOTES_CHAPTERS
        ),
    )
    content = ids(
        src,
        f"SELECT DISTINCT content_id FROM theology_verse_index WHERE "
        f"{chapter_clause('book', 'chapter', chapters=NOTES_CHAPTERS)}",
    )
    return {
        "aquifer_content": range_clause(
            "book_num", "chapter_start", "chapter_end", books=lambda c: c[3], chapters=NOTES_CHAPTERS
        ),
        "ane_entries": f"id IN {in_list(entries)}",
        "ane_book_mappings": f"entry_id IN {in_list(entries)}",
        "theology_content": f"id IN {in_list(content)}",
        "theology_verse_index": f"content_id IN {in_list(content)}",
        "theology_themes": "1",
        "theology_theme_index": f"content_id IN {in_list(content)}",
    }


def lxx_filters(_src: sqlite3.Connection) -> dict[str, str]:
    return {"biblical_version_verses": chapter_clause("canonical_book", "canonical_chapter")}


def ancient_filters(src: sqlite3.Connection) -> dict[str, str]:
    passages = ids(
        src,
        "SELECT DISTINCT passage_id FROM ancient_source_biblical_links WHERE "
        + sort_clause("biblical_book", "sort_start", "sort_end"),
    )
    return {
        "ancient_source_passages": f"id IN {in_list(passages)}",
        "ancient_source_passages_fts": f"rowid IN {in_list(passages)}",
        "ancient_source_biblical_links": f"passage_id IN {in_list(passages)}",
        "ancient_source_notes": f"passage_id IN {in_list(passages)}",
    }


PACKS = {
    "core": core_filters,
    "graph": graph_filters,
    "notes": notes_filters,
    "lxx": lxx_filters,
    "ancient": ancient_filters,
}


def schema(conn: sqlite3.Connection):
    rows = conn.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").fetchall()
    virtual = {n for t, n, _, sql in rows if t == "table" and sql and sql.startswith("CREATE VIRTUAL TABLE")}
    shadows = {f"{v}{s}" for v in virtual for s in FTS5_SHADOWS}
    tables = {n: sql for t, n, _, sql in rows if t == "table" and not n.startswith("sqlite_") and n not in shadows}
    indexes = [(tbl, sql) for t, _, tbl, sql in rows if t == "index" and sql]
    return tables, virtual, indexes


def cut(src_path: Path, out: Path, filters_for) -> None:
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    tables, virtual, indexes = schema(src)
    filters = filters_for(src)
    src.close()
    unplaced = sorted(set(tables) - set(filters) - {"pack_meta"})
    if unplaced:
        sys.exit(f"{src_path.name}: no fixture filter for {unplaced}")

    if out.exists():
        out.unlink()
    dst = sqlite3.connect(f"file:{out}", uri=True, isolation_level=None)
    dst.execute("PRAGMA page_size = 4096")
    dst.execute("PRAGMA journal_mode = OFF")
    dst.execute("ATTACH DATABASE ? AS src", (f"file:{src_path}?mode=ro",))
    dst.execute("BEGIN")
    for table, sql in tables.items():
        dst.execute(sql)
        where = filters.get(table, "1")
        if table in virtual:
            columns = ", ".join(f'"{r[1]}"' for r in dst.execute(f'PRAGMA src.table_info("{table}")'))
            dst.execute(
                f'INSERT INTO main."{table}"(rowid, {columns}) '
                f'SELECT rowid, {columns} FROM src."{table}" WHERE {where} ORDER BY rowid'
            )
        else:
            order = "" if "WITHOUT ROWID" in sql.upper() else " ORDER BY rowid"
            dst.execute(f'INSERT INTO main."{table}" SELECT * FROM src."{table}" WHERE {where}{order}')
        for tbl, index_sql in indexes:
            if tbl == table:
                dst.execute(index_sql)
    if dst.execute("SELECT 1 FROM main.sqlite_master WHERE name = 'sqlite_sequence'").fetchone():
        dst.execute("DELETE FROM main.sqlite_sequence")
        dst.execute("INSERT INTO main.sqlite_sequence SELECT name, seq FROM src.sqlite_sequence")
    dst.execute("INSERT INTO main.pack_meta VALUES ('fixture', 'cut by data/scripts/make_fixtures.py')")
    dst.execute("COMMIT")
    dst.execute("DETACH DATABASE src")
    dst.execute("VACUUM")
    integrity = dst.execute("PRAGMA integrity_check").fetchone()[0]
    counts = {t: dst.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in tables}
    dst.close()
    if integrity != "ok":
        sys.exit(f"{out}: integrity_check {integrity}")
    rows = ", ".join(f"{t} {n}" for t, n in counts.items())
    print(f"  {out.name}: {out.stat().st_size / 1e6:.2f} MB ({rows})")


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--packs", type=Path, default=root / "data" / "out")
    parser.add_argument("--out", type=Path, default=root / "test" / "fixtures" / "packs")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for name, filters in PACKS.items():
        cut(args.packs / f"{name}.sqlite", args.out / f"{name}.sqlite", filters)


if __name__ == "__main__":
    main()
