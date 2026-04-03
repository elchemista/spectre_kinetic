# Reranker Training

This document explains how the reranker training pipeline works in `spectre_kinetic`, what gets trained, how the trained model is used at runtime, and why the current design is efficient enough to use as a bounded fallback.

## What The Reranker Is For

The reranker is **not** the primary retrieval system.

Primary selection still happens in the planner using:

- encoder embedding similarity
- lexical overlap
- alias overlap
- shape score

That first stage produces a ranked candidate list.

The reranker is only used as a **bounded fallback** when the first-stage result is uncertain.

Today the planner triggers reranking only when all of these are true:

- `tool_selection_fallback == :reranker`
- a reranker runtime is loaded
- the first-stage choice is weak or ambiguous

The ambiguity conditions are:

- top candidate is below `tool_threshold`
- required args are still missing after slot mapping
- margin between top-1 and top-2 is less than or equal to `fallback_margin`

When that happens, the planner reranks only the top `fallback_top_k` candidates, not the full registry.

That logic lives in [lib/planner/planner.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/planner/planner.ex).

## High-Level Flow

The training pipeline is:

1. Read a JSONL dataset of labeled `(query, tool_card, label)` pairs.
2. Embed the query text with the encoder.
3. Embed the tool card text with the same encoder.
4. Build pairwise numeric features from those two embeddings.
5. Train a small MLP classifier in Axon.
6. Run the trained model back over the training matrix.
7. Derive simple calibration thresholds from the resulting scores.
8. Save the trained parameters and metadata.

The training code is in [lib/reranker/trainer.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/reranker/trainer.ex).

## Training Command

Run:

```bash
mix spectre.train_reranker \
  --encoder artifacts/encoder \
  --dataset data/reranker.jsonl \
  --out artifacts/reranker
```

Supported options:

- `--encoder`
- `--dataset`
- `--out`
- `--hidden_dim`
- `--batch_size`
- `--epochs`
- `--learning_rate`

The task implementation is in [lib/mix/tasks/spectre.train_reranker.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/mix/tasks/spectre.train_reranker.ex).

## Dataset Format

Each JSONL line must contain:

```json
{"query":"send message to dev@example.com","tool_card":"Dynamic.Email.send - ...","label":1}
```

Meaning:

- `query`: the user request or AL-like text you want to match
- `tool_card`: the textual representation of one candidate tool
- `label`: `1` if this query-tool pair is a good match, `0` if not

The important detail is that the reranker learns **pair quality**, not standalone query embeddings and not standalone tool embeddings.

## What Is A Tool Card

The reranker does not train directly on raw registry JSON.

It trains on `tool_card` text, which is the compact textual representation of a tool built from fields like:

- module
- function name
- doc
- argument names
- examples

That same tool-card shape is what the planner reranks at runtime.

This matters because the reranker sees the same type of candidate text during training and inference.

## How Features Are Built

The reranker is **not** a cross-encoder.

It is a compact classifier over encoder-derived pair features.

For each training example:

1. the query is embedded with the encoder
2. the tool card is embedded with the same encoder
3. the feature vector is built as:

```text
[q, t, abs(q - t), q * t]
```

Where:

- `q` is the query embedding
- `t` is the tool-card embedding
- `abs(q - t)` captures distance-like disagreement
- `q * t` captures elementwise interaction

This logic lives in [lib/reranker/feature_builder.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/reranker/feature_builder.ex).

If the encoder embedding dimension is `d`, the final feature dimension is:

```text
4 * d
```

So with a `384`-dim encoder, the reranker input is `1536` floats per pair.

## Model Shape

The model is intentionally small.

Current architecture:

1. input layer with shape `{nil, feature_dim}`
2. dense layer with `hidden_dim` units and `relu`
3. dropout with rate `0.1`
4. final dense layer with `1` unit and `sigmoid`

In Axon terms:

```elixir
Axon.input("pair_features", shape: {nil, input_dim})
|> Axon.dense(hidden_dim, activation: :relu)
|> Axon.dropout(rate: 0.1)
|> Axon.dense(1, activation: :sigmoid)
```

This is a binary classifier that outputs a score in `[0, 1]`.

It answers:

`How likely is this query-tool pair to be a good match?`

## Optimization

Current training setup:

- loss: binary cross entropy
- optimizer: `adamw`
- default learning rate: `1.0e-3`
- default batch size: `32`
- default epochs: `5`
- default hidden dimension: `128`

This is intentionally lightweight.

The goal is not to train a giant model inside `spectre_kinetic`.
The goal is to learn a cheap second-stage ranking signal that can correct hard edge cases from the first-stage planner.

## What Gets Saved

Training writes:

- `params.etf`
- `metadata.json`
- `calibration.json`

Typical output:

```text
artifacts/reranker/
├── calibration.json
├── metadata.json
└── params.etf
```

### `params.etf`

Serialized Axon model state.

This contains the learned weights.

### `metadata.json`

Training metadata, currently including:

- `encoder_model_dir`
- `feature_dim`
- `hidden_dim`
- `batch_size`
- `epochs`
- `learning_rate`
- `example_count`
- `generated_at`

### `calibration.json`

Simple score thresholds derived from the labeled scores produced by the trained model.

The current calibration builder emits:

- `reranker_accept_threshold`
- `reranker_reject_threshold`
- positive and negative example counts

That logic is in [lib/reranker/calibration.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/reranker/calibration.ex).

## How Calibration Works

After training finishes, the model is run back over the full feature matrix.

That gives one score per labeled example.

Then:

- positive examples are collected and sorted
- negative examples are collected and sorted
- thresholds are taken from simple quantiles

Current default quantile is `0.1`.

So roughly:

- accept threshold comes from the lower tail of positive scores
- reject threshold comes from the upper tail of negative scores

This is a lightweight calibration pass, not full probability calibration.

It is useful as tuning metadata, but the runtime does not currently auto-apply these thresholds.

## How The Trained Reranker Is Used At Runtime

The Axon reranker runtime is implemented in [lib/reranker/runtime/axon.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/reranker/runtime/axon.ex).

At runtime it:

1. loads `params.etf`
2. loads `metadata.json`
3. loads the encoder referenced by `metadata["encoder_model_dir"]` unless an explicit `encoder_model_dir` override is passed
4. rebuilds the same Axon model shape from `feature_dim` and `hidden_dim`
5. scores pairs by rebuilding the exact same `[q, t, abs(q - t), q * t]` features

So training and inference are shape-compatible by construction.

## How The Planner Calls The Reranker

When reranker fallback is activated:

1. the planner takes the top `fallback_top_k` first-stage candidates
2. it builds pairs of:

   - `query = original AL text`
   - `tool_card = candidate tool card`

3. it sends those pairs to `score_batch/2`
4. it sorts candidates by:

   - reranker score first
   - fused first-stage score second

5. it keeps the highest-ranked candidate
6. it runs normal deterministic slot mapping on that chosen tool

So the reranker changes **tool choice**, but it does **not** replace the slot mapper.

Argument filling stays deterministic and schema-aware after reranking.

## Why This Is Efficient

The current design is efficient for four reasons.

### 1. It is only a fallback

The reranker does not run on every request.

It runs only on uncertain cases.

That means the average request cost stays close to the cheaper first-stage planner.

### 2. It reranks only top-K candidates

The planner never reranks the whole registry.

It reranks only the top `fallback_top_k` candidates.

If `fallback_top_k = 3`, only three query-tool pairs are rescored.

This is the main bounded-cost property of the design.

### 3. It is a small MLP, not a full cross-encoder

The expensive semantic work is delegated to the encoder embeddings.

The reranker itself is just a compact classifier over pairwise embedding features.

That is much cheaper than token-level joint attention over every query-tool pair.

### 4. Tool cards are short structured text

The reranker operates on compact tool-card text, not on huge raw tool definitions.

That keeps embedding and pair construction relatively small.

## Why This Can Still Improve Results

The first-stage fused score is good at broad retrieval.

But there are cases where top candidates are close:

- email vs sms
- note insert vs task create
- tools sharing overlapping aliases
- cases where retrieval is strong but slot fit is incomplete

The reranker helps because it learns from labeled examples of:

- what query wording usually goes with what tool-card wording
- how positive and negative pairs differ after embedding
- patterns that a simple fused retrieval score may not separate cleanly

So it acts as a targeted second opinion for ambiguous tool choice.

## What It Does Not Do

The current reranker does not:

- generate arguments
- execute tools
- replace deterministic slot mapping
- inspect the full registry at fallback time
- automatically consume `calibration.json` inside the planner

It is strictly a bounded tool-choice rescoring layer.

## Important Artifact Split

This project currently has **two reranker runtime stories**.

### ONNX reranker runtime

The default runtime module is [lib/reranker/runtime.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/reranker/runtime.ex).

It expects:

- `model.onnx`
- `tokenizer.json`

This is a token-level pair scorer using ONNX and `Tokenizers`.

### Axon reranker runtime

The training pipeline in this repo produces artifacts for [lib/reranker/runtime/axon.ex](/home/dev/Sviluppo/personal/spectre_kinetic/lib/reranker/runtime/axon.ex).

It expects:

- `params.etf`
- `metadata.json`

This is the runtime that matches `mix spectre.train_reranker`.

### Practical consequence

Training with `mix spectre.train_reranker` does **not** produce artifacts for the default ONNX reranker runtime.

To use the trained Axon reranker, load the planner with:

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    registry_json: "/abs/path/to/registry.json",
    encoder_model_dir: "/abs/path/to/artifacts/encoder",
    tool_selection_fallback: :reranker,
    fallback_model_dir: "/abs/path/to/artifacts/reranker",
    fallback_runtime_module: SpectreKinetic.Reranker.Runtime.Axon
  )
```

## Choosing Good Training Data

The reranker is only as good as its pair labels.

Good positive pairs:

- realistic user requests
- realistic AL commands
- multiple phrasings for the same tool
- cases that are easy to confuse with other tools

Good negative pairs:

- semantically nearby tools
- tools sharing aliases
- tools with similar docs but different required args

Easy random negatives are useful, but hard negatives are much more valuable for reranking.

## Recommended Data Sources

Useful sources for building reranker datasets:

- canonical `@al` declarations from code-defined tools
- `AL:` examples embedded in docs
- registry examples
- planner failures from ambiguous real traffic
- synthetic near-miss pairs between similar tools

The most valuable data usually comes from confusion sets, not from easy unrelated pairs.

## Current Limitations

- no validation split or early stopping is built in yet
- no automatic hard-negative mining task yet
- no direct export from Axon reranker to ONNX in this repo yet
- `calibration.json` is informative but not auto-wired into runtime selection
- the runtime fallback still depends on the user selecting the correct reranker runtime module

## Summary

The current reranker design is:

- encoder-based
- pair-feature based
- small and cheap
- bounded to top-K fallback usage
- trained in Elixir with `Nx` and `Axon`
- deterministic in how it integrates with the planner

That makes it a pragmatic second-stage selector: more expressive than the first-stage score fusion, but much cheaper than reranking the whole registry with a large joint model.
