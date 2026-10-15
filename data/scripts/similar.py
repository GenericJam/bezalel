"""Precompute each verse's nearest verses and passages into plain tables, so the phone
needs no vector extension.

  python similar.py --db DB --texts TEXTS.tsv --model MODEL_DIR [--k 20]

Embeds each verse's English text (TEXTS.tsv from embed_input.py) with
BAAI/bge-small-en-v1.5 (ONNX, CLS pooling, L2-normalised). A passage's vector is
the normalised mean of its verses' vectors. Similarity is cosine.

Writes into DB:
  similar_verses(verse_id, rank, similar_verse_id, similarity_permille)
  similar_passages(verse_id, rank, passage_id, similarity_permille)

similar_passages leaves out the passage that contains the verse, as studybible-mcp's
find_similar_passages does. similarity_permille is round(cosine * 1000); ties are
ordered by id, so the tables are a pure function of the vectors.
"""

from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

BATCH = 64
THREADS = 1  # one thread: float reductions in the same order every run
MAX_TOKENS = 512


def embed(texts: list[str], model_dir: Path) -> np.ndarray:
    tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
    tokenizer.enable_truncation(MAX_TOKENS)
    options = ort.SessionOptions()
    options.intra_op_num_threads = THREADS
    options.inter_op_num_threads = 1
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    session = ort.InferenceSession(
        str(model_dir / "model.onnx"), options, providers=["CPUExecutionProvider"]
    )
    vectors = np.zeros((len(texts), 384), dtype=np.float32)
    order = sorted(range(len(texts)), key=lambda i: (len(texts[i]), i))
    for start in range(0, len(order), BATCH):
        index = order[start:start + BATCH]
        encodings = tokenizer.encode_batch([texts[i] for i in index])
        width = max(len(e.ids) for e in encodings)
        input_ids = np.zeros((len(index), width), dtype=np.int64)
        mask = np.zeros_like(input_ids)
        for row, encoding in enumerate(encodings):
            input_ids[row, :len(encoding.ids)] = encoding.ids
            mask[row, :len(encoding.ids)] = 1
        hidden = session.run(
            None,
            {"input_ids": input_ids, "attention_mask": mask, "token_type_ids": np.zeros_like(input_ids)},
        )[0]
        vectors[index] = hidden[:, 0, :]
    return vectors / np.linalg.norm(vectors, axis=1, keepdims=True)


def top_k(queries: np.ndarray, corpus: np.ndarray, ids: np.ndarray, excluded, k: int):
    """Yield (query_index, [(id, permille), ...]) for every query row: the k corpus
    rows with the highest round(cosine * 1000), ties by lower id.

    excluded(query_index) returns a boolean mask over corpus rows to leave out.
    """
    for start in range(0, len(queries), 1024):
        block = np.rint(queries[start:start + 1024] @ corpus.T * 1000).astype(np.int64)
        for offset, permille in enumerate(block):
            q = start + offset
            allowed = ~excluded(q)
            values, members = permille[allowed], ids[allowed]
            n = min(k, len(values))
            cutoff = np.partition(values, len(values) - n)[len(values) - n]
            chosen = values >= cutoff  # every row tied at the cutoff, so ids decide
            order = np.lexsort((members[chosen], -values[chosen]))[:n]
            yield q, [(int(members[chosen][i]), int(values[chosen][i])) for i in order]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--texts", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--k", type=int, default=20)
    args = parser.parse_args()

    verse_ids, texts = [], []
    for line in args.texts.read_text(encoding="utf-8").splitlines():
        verse_id, _source, text = line.split("\t", 2)
        verse_ids.append(int(verse_id))
        texts.append(text)
    verse_ids = np.array(verse_ids, dtype=np.int64)
    print(f"  embedding {len(texts)} verses")
    vectors = embed(texts, args.model)

    conn = sqlite3.connect(args.db)
    row_of = {int(v): i for i, v in enumerate(verse_ids)}
    passages = conn.execute(
        "SELECT id, start_verse_id, end_verse_id FROM passages ORDER BY id"
    ).fetchall()
    passage_ids, passage_vectors, spans = [], [], []
    for passage_id, first, last in passages:
        rows = [row_of[v] for v in range(first, last + 1) if v in row_of]
        if not rows:
            continue
        mean = vectors[rows].mean(axis=0)
        passage_ids.append(passage_id)
        passage_vectors.append(mean / np.linalg.norm(mean))
        spans.append((first, last))
    passage_ids = np.array(passage_ids, dtype=np.int64)
    passage_vectors = np.vstack(passage_vectors).astype(np.float32)
    starts = np.array([s for s, _ in spans])
    ends = np.array([e for _, e in spans])
    print(f"  {len(passage_ids)} of {len(passages)} passages have verse vectors")

    conn.executescript("""
        DROP TABLE IF EXISTS similar_verses;
        DROP TABLE IF EXISTS similar_passages;
        CREATE TABLE similar_verses (
            verse_id INTEGER NOT NULL,
            rank INTEGER NOT NULL,
            similar_verse_id INTEGER NOT NULL,
            similarity_permille INTEGER NOT NULL,
            PRIMARY KEY (verse_id, rank)
        ) WITHOUT ROWID;
        CREATE TABLE similar_passages (
            verse_id INTEGER NOT NULL,
            rank INTEGER NOT NULL,
            passage_id INTEGER NOT NULL,
            similarity_permille INTEGER NOT NULL,
            PRIMARY KEY (verse_id, rank)
        ) WITHOUT ROWID;
    """)

    def not_self(q: int) -> np.ndarray:
        mask = np.zeros(len(verse_ids), dtype=bool)
        mask[q] = True
        return mask

    def containing(q: int) -> np.ndarray:
        verse_id = verse_ids[q]
        return (starts <= verse_id) & (ends >= verse_id)

    for table, corpus, ids, excluded in (
        ("similar_verses", vectors, verse_ids, not_self),
        ("similar_passages", passage_vectors, passage_ids, containing),
    ):
        rows = [
            (int(verse_ids[q]), rank, neighbour, permille)
            for q, neighbours in top_k(vectors, corpus, ids, excluded, args.k)
            for rank, (neighbour, permille) in enumerate(neighbours, 1)
        ]
        conn.executemany(f"INSERT INTO {table} VALUES (?, ?, ?, ?)", rows)
        print(f"  {table}: {len(rows)} rows")
    conn.commit()
    conn.close()


if __name__ == "__main__":
    main()
