"""Write the English text of every verse row, as studybible-mcp's verse tools show it,
for the embedding step.

Runs with the checkout's Python and uses its own StudyBibleDB.attach_bsb_text, so a
row gets the same Berean Standard Bible text lookup_verse shows. Rows without BSB
text (the textual-variant verses the BSB omits, Psalm superscriptions, the second
row of a split-numbered verse) fall back to the STEPBible word-gloss text.

  python embed_input.py --checkout CHECKOUT --db DB --out OUT.tsv

OUT.tsv columns: verse_id, source (bsb|gloss), text. Rows with neither are omitted.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path


async def dump(checkout: Path, db_path: Path, out: Path) -> None:
    sys.path.insert(0, str(checkout / "src"))
    from study_bible_mcp.database import StudyBibleDB

    db = StudyBibleDB(db_path)
    await db.connect()
    try:
        rows = await db._fetchall("SELECT id, reference, text_english FROM verses ORDER BY id")
        rows = await db.attach_bsb_text([dict(row) for row in rows])
    finally:
        await db.close()

    counts = {"bsb": 0, "gloss": 0, "none": 0}
    with open(out, "w", encoding="utf-8", newline="\n") as file:
        for row in rows:
            if row.get("text_bsb"):
                source, text = "bsb", row["text_bsb"]
            elif (row["text_english"] or "").strip():
                source, text = "gloss", row["text_english"]
            else:
                counts["none"] += 1
                continue
            counts[source] += 1
            text = " ".join(text.split())  # one line, no tabs
            file.write(f"{row['id']}\t{source}\t{text}\n")
    print(f"  verse texts: {counts['bsb']} BSB, {counts['gloss']} gloss, {counts['none']} without text")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    asyncio.run(dump(args.checkout, args.db, args.out))


if __name__ == "__main__":
    main()
