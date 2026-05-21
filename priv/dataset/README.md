# Built-In Classifier Training Datasets

These JSONL files are editable seed datasets for the optional built-in Axon
classifiers:

- `plan_confidence.jsonl`
- `slot_confidence.jsonl`
- `safety_risk.jsonl`

They do not store raw feature vectors. Each row stores source information such
as AL input text, selected tool/action context, mapped args, missing fields,
planner scores, slot definitions, and the expected label. The training task
turns those rows into numeric features with the same feature builders used at
runtime.

Legacy rows with explicit `features` and `label` still work for experiments,
but the bundled datasets avoid that format so they are easy to edit.

## Important: Run The Encoder/Registry Step First

The classifier datasets are based on planner output. In a real project, planner
output depends on your tool registry and encoder embeddings. So the normal flow
is:

1. Download or prepare an encoder model.
2. Extract your tools into a registry.
3. Compile the registry with encoder embeddings.
4. Run/collect planner examples and labels.
5. Train classifiers from those labeled source examples.

The tiny bundled seed rows can be trained immediately because they already
include synthetic planner scores/action context. For your own dataset, create
rows from real planner outputs after the registry is embedded.

## 1. Download The Encoder

```bash
mix spectre.download_encoder \
  --model BAAI/bge-small-en-v1.5 \
  --out artifacts/encoder
```

This downloads `model.onnx`, `tokenizer.json`, and `config.json` into
`artifacts/encoder`. The planner uses this encoder to embed tool text and match
AL input to tools.

## 2. Extract Or Compile Your Tool Registry

To extract tools from your Elixir app into JSON:

```bash
mix extract_kinetic \
  --app my_app \
  --out artifacts/registry/registry.json
```

This scans modules in `my_app` for Spectre-visible tools and writes a registry
JSON file.

Then compile that JSON with encoder embeddings:

```bash
mix compile_kinetic \
  --registry artifacts/registry/registry.json \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

This embeds the registry tool cards and writes an ETF bundle. At runtime, this
is faster than re-reading JSON and recomputing embeddings.

You can also extract and compile in one command:

```bash
mix extract_kinetic \
  --app my_app \
  --encoder artifacts/encoder \
  --out artifacts/registry/registry.etf
```

## 3. Build Classifier Dataset Rows

Each classifier expects slightly different source fields.

### PlanConfidence

Use this for “is the whole selected plan confident enough?”

```json
{"input":"LIST DIRECTORY WITH: PATH=\"/tmp\"","selected_tool":"Linux.Coreutils.ls/1","args":{"path":"/tmp"},"missing":[],"scores":{"combined_score":0.94,"confidence":0.93,"tool_score":0.95,"mapping_score":0.92},"candidates":[{"score":0.94},{"score":0.31}],"label":1}
```

Label:

- `1` means the plan should be accepted.
- `0` means it should require clarification/confirmation or be rejected.

### SlotConfidence

Use this for “is this mapped argument/slot correct?”

```json
{"input":"LIST DIRECTORY WITH: FILE=\"/var/log\"","args":{"path":"/var/log"},"missing":[],"arg":{"name":"path","type":"String.t()","required":true,"aliases":["file","dir"]},"label":1}
```

Label:

- `1` means the slot mapping is good.
- `0` means the slot is missing, wrong, ambiguous, or shape-mismatched.

### SafetyRisk

Use this for “what risk class does this selected action have?”

```json
{"input":"DELETE FILE WITH: PATH=\"/tmp/old.log\" FORCE=true","selected_tool":"Files.delete/1","args":{"path":"/tmp/old.log","force":true},"missing":[],"action":{"id":"Files.delete/1","module":"Files","name":"delete","doc":"Delete or remove a file","spec":"delete(path :: String.t()) :: :ok","args":[{"name":"path","type":"String.t()","required":true},{"name":"force","type":"boolean()","required":false}],"examples":["DELETE FILE WITH: PATH=\"/tmp/old.log\""]},"label":"destructive"}
```

Labels:

- `safe`
- `external_side_effect`
- `destructive`
- `financial`
- `credential_sensitive`
- `system_mutation`
- `network_action`
- `unknown_risk`

## 4. Train The Built-In Classifiers

Train from the bundled seed dataset:

```bash
mix spectre.train_classifier plan_confidence \
  --out artifacts/classifiers/plan_confidence

mix spectre.train_classifier slot_confidence \
  --out artifacts/classifiers/slot_confidence

mix spectre.train_classifier safety_risk \
  --out artifacts/classifiers/safety_risk
```

The task knows the bundled dataset paths, so `--dataset` is optional for these
three built-ins.

Train from your own dataset:

```bash
mix spectre.train_classifier plan_confidence \
  --dataset data/classifiers/plan_confidence.jsonl \
  --out artifacts/classifiers/plan_confidence

mix spectre.train_classifier slot_confidence \
  --dataset data/classifiers/slot_confidence.jsonl \
  --out artifacts/classifiers/slot_confidence

mix spectre.train_classifier safety_risk \
  --dataset data/classifiers/safety_risk.jsonl \
  --out artifacts/classifiers/safety_risk
```

Each command writes:

- `params.etf`: trained Axon model parameters.
- `metadata.json`: classifier id, feature dimension, feature names, training settings.
- `calibration.json`: simple training summary/calibration metadata.

Useful training options:

```bash
mix spectre.train_classifier plan_confidence \
  --dataset data/classifiers/plan_confidence.jsonl \
  --out artifacts/classifiers/plan_confidence \
  --epochs 20 \
  --hidden-dim 32 \
  --batch-size 16 \
  --learning-rate 0.001 \
  --seed 42
```

## 5. Use The Trained Classifiers At Runtime

```elixir
runtime =
  SpectreKinetic.load_runtime!(
    compiled_registry: "artifacts/registry/registry.etf",
    classifiers: [
      {SpectreKinetic.Classifiers.PlanConfidence,
       model_dir: "artifacts/classifiers/plan_confidence"},
      {SpectreKinetic.Classifiers.SlotConfidence,
       model_dir: "artifacts/classifiers/slot_confidence"},
      {SpectreKinetic.Classifiers.SafetyRisk,
       model_dir: "artifacts/classifiers/safety_risk"}
    ]
  )

{:ok, action} =
  SpectreKinetic.plan(runtime, ~s(LIST DIRECTORY WITH: PATH="/tmp"))
```

`compiled_registry` loads the embedded planner registry. Each classifier
`model_dir` loads the artifacts produced by `mix spectre.train_classifier`.

For development without trained artifacts, use deterministic heuristics:

```elixir
classifiers: [
  {SpectreKinetic.Classifiers.PlanConfidence, fallback: :heuristic},
  {SpectreKinetic.Classifiers.SlotConfidence, fallback: :heuristic},
  {SpectreKinetic.Classifiers.SafetyRisk, fallback: :heuristic}
]
```

## Editing Tips

- Add more rows by copying an existing row and changing the source fields.
- Keep labels consistent; noisy labels make the classifier worse.
- Prefer rows collected from real planner outputs after embedding your real tool registry.
- Do not hand-edit feature vectors unless you are debugging the feature builder itself.
