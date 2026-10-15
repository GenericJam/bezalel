"""Split the full study database into pack files (packs.json) and measure them.

  python make_packs.py --db DB --packs packs.json --pins pins.json --out OUT

Every table in DB must be assigned to exactly one pack or listed under "drop_empty"
(which must be empty); every view must be listed under "drop_views". A table the
pin adds therefore stops the build instead of being silently left out.

Each pack is a standalone SQLite file (page size 4096, rollback journal) holding its
tables with their original schemas, indexes and AUTOINCREMENT counters, the FTS5
tables rebuilt row for row and optimised, ANALYZE statistics, and a pack_meta
table. Table names are unique across packs, so the app can open one pack or ATTACH
several. OUT also gets <pack>.sqlite.zst and sizes.tsv.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

FTS5_SHADOWS = ("_data", "_idx", "_content", "_docsize", "_config")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def gzip_size(path: Path) -> int:
    class Counter:
        size = 0

        def write(self, data: bytes) -> None:
            self.size += len(data)

        def flush(self) -> None:
            pass

    counter = Counter()
    with open(path, "rb") as source, gzip.GzipFile(fileobj=counter, mode="wb", compresslevel=9, mtime=0) as out:
        for block in iter(lambda: source.read(1 << 20), b""):
            out.write(block)
    return counter.size


def schema(conn: sqlite3.Connection):
    rows = conn.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
    ).fetchall()
    virtual = {name for type_, name, _, sql in rows if type_ == "table" and sql and sql.startswith("CREATE VIRTUAL TABLE")}
    shadows = {f"{v}{suffix}" for v in virtual for suffix in FTS5_SHADOWS}
    tables = {
        name: sql for type_, name, _, sql in rows
        if type_ == "table" and not name.startswith("sqlite_") and name not in shadows
    }
    views = {name for type_, name, _, _ in rows if type_ == "view"}
    indexes = [(tbl, sql) for type_, _, tbl, sql in rows if type_ == "index" and sql]
    triggers = [name for type_, name, _, _ in rows if type_ == "trigger"]
    return tables, virtual, views, indexes, triggers


def copy_pack(src_path: Path, out: Path, name: str, spec: dict, meta: dict, tables, virtual, indexes) -> None:
    if out.exists():
        out.unlink()
    dst = sqlite3.connect(f"file:{out}", uri=True, isolation_level=None)
    dst.execute("PRAGMA page_size = 4096")
    dst.execute("PRAGMA journal_mode = OFF")
    dst.execute("PRAGMA synchronous = OFF")
    dst.execute("ATTACH DATABASE ? AS src", (f"file:{src_path}?mode=ro",))
    dst.execute("BEGIN")
    for table in spec["tables"]:
        dst.execute(tables[table])
        if table in virtual:
            columns = [row[1] for row in dst.execute(f'PRAGMA src.table_info("{table}")')]
            column_list = ", ".join(f'"{c}"' for c in columns)
            dst.execute(
                f'INSERT INTO main."{table}"(rowid, {column_list}) '
                f'SELECT rowid, {column_list} FROM src."{table}" ORDER BY rowid'
            )
            dst.execute(f'INSERT INTO main."{table}"("{table}") VALUES (\'optimize\')')
        else:
            without_rowid = "WITHOUT ROWID" in tables[table].upper()
            order = "" if without_rowid else " ORDER BY rowid"
            dst.execute(f'INSERT INTO main."{table}" SELECT * FROM src."{table}"{order}')
        for tbl, sql in indexes:
            if tbl == table:
                dst.execute(sql)
    has_sequence = dst.execute(
        "SELECT 1 FROM main.sqlite_master WHERE name = 'sqlite_sequence'"
    ).fetchone()
    if has_sequence:
        dst.execute("DELETE FROM main.sqlite_sequence")
        placeholders = ",".join("?" * len(spec["tables"]))
        dst.execute(
            f"INSERT INTO main.sqlite_sequence SELECT name, seq FROM src.sqlite_sequence "
            f"WHERE name IN ({placeholders}) ORDER BY name",
            spec["tables"],
        )
    dst.execute("CREATE TABLE pack_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
    dst.executemany(
        "INSERT INTO pack_meta VALUES (?, ?)",
        sorted({**meta, "pack": name, "description": spec["description"],
                "tables": " ".join(spec["tables"])}.items()),
    )
    dst.execute("COMMIT")
    dst.execute("DETACH DATABASE src")
    dst.execute("ANALYZE")
    dst.execute("VACUUM")
    integrity = dst.execute("PRAGMA integrity_check").fetchone()[0]
    dst.close()
    if integrity != "ok":
        sys.exit(f"{out}: integrity_check {integrity}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--packs", type=Path, required=True)
    parser.add_argument("--pins", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    config = json.loads(args.packs.read_text())
    pins = json.loads(args.pins.read_text())
    packs = config["packs"]

    src = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    tables, virtual, views, indexes, triggers = schema(src)
    if triggers:
        sys.exit(f"Triggers are not handled: {triggers}")

    assigned = [t for spec in packs.values() for t in spec["tables"]]
    duplicates = sorted({t for t in assigned if assigned.count(t) > 1})
    unknown = sorted(set(assigned + config["drop_empty"]) - set(tables))
    unassigned = sorted(set(tables) - set(assigned) - set(config["drop_empty"]))
    stray_views = sorted(views - set(config["drop_views"]))
    nonempty_dropped = [
        t for t in config["drop_empty"] if t in tables
        and src.execute(f'SELECT EXISTS (SELECT 1 FROM "{t}")').fetchone()[0]
    ]
    problems = {
        "assigned twice": duplicates, "not in the database": unknown,
        "not assigned to a pack": unassigned, "views not listed": stray_views,
        "drop_empty tables with rows": nonempty_dropped,
    }
    if any(problems.values()):
        sys.exit("packs.json does not match the database: " + json.dumps({k: v for k, v in problems.items() if v}))
    row_counts = {t: src.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in assigned}
    src.close()

    meta = {
        "studybible_mcp_commit": pins["studybible_mcp"]["commit"],
        "sqlite_version": sqlite3.sqlite_version,
        "similar_model": f"{pins['embedding_model']['repo']}@{pins['embedding_model']['revision']}",
        "licences": "See SOURCES.md in the Bezalel repository; attributions are shown in the app.",
    }

    args.out.mkdir(parents=True, exist_ok=True)
    lines = ["pack\ttables\trows\traw_bytes\tgzip9_bytes\tzstd19_bytes\tsha256\tzst_sha256"]
    for name, spec in packs.items():
        out = args.out / f"{name}.sqlite"
        copy_pack(args.db, out, name, spec, meta, tables, virtual, indexes)
        zst = args.out / f"{name}.sqlite.zst"
        subprocess.run(["zstd", "-19", "-q", "-f", "--no-progress", str(out), "-o", str(zst)], check=True)
        rows = sum(row_counts[t] for t in spec["tables"])
        sizes = (out.stat().st_size, gzip_size(out), zst.stat().st_size)
        lines.append("\t".join(map(str, (name, len(spec["tables"]), rows, *sizes, sha256_file(out), sha256_file(zst)))))
        print(f"  {name}: {rows} rows, {sizes[0] / 1e6:.1f} MB raw, {sizes[1] / 1e6:.1f} MB gzip, {sizes[2] / 1e6:.1f} MB zstd")
    (args.out / "sizes.tsv").write_text("\n".join(lines) + "\n")
    (args.out / "tables.tsv").write_text(
        "pack\ttable\trows\n" + "".join(
            f"{name}\t{t}\t{row_counts[t]}\n" for name, spec in packs.items() for t in spec["tables"]
        )
    )


if __name__ == "__main__":
    main()
