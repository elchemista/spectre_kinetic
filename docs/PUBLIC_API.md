# Spectre Kinetic public API — 0.1.0

This file is the normative public API manifest for Spectre Kinetic `0.1.0`.
The core planning toolkit remains independent from Spectre. The optional
adapter implements Stack contract 1 but
requires Spectre `~> 0.3.2`. Compatibility guarantees apply only to the
modules and callables listed below. Any module, function, macro, or callback
not listed here is an implementation detail even when it is exported or
visible in generated docs.

Default arguments are expanded into every callable arity. For the listed
modules, documented types, opaque types, and documented struct fields are also
public. Modules with no callable row expose only their documented module,
type, and struct contract.

## Manifest

- `Mix.Tasks.SpectreKinetic.Compile`
- `Mix.Tasks.SpectreKinetic.DownloadEncoder`
- `Mix.Tasks.SpectreKinetic.Extract`
- `Mix.Tasks.SpectreKinetic.Show`
- `Mix.Tasks.SpectreKinetic.TrainClassifier`
- `Mix.Tasks.SpectreKinetic.TrainReranker`
- `Spectre.Kinetic`
  - functions: `config/1`
- `Spectre.Kinetic.Actions`
- `Spectre.Kinetic.Planner`
- `SpectreKinetic`
  - functions: `action_count/1`, `action_definitions/1`, `add_action/2`, `al_prompt/0`, `al_prompt/1`, `al_prompt!/0`, `al_prompt!/1`, `child_spec/1`, `close_runtime/1`, `delete_action/2`, `dictionary/0`, `dictionary/1`, `dictionary!/0`, `dictionary!/1`, `dictionary_text/0`, `dictionary_text/1`, `dictionary_text!/0`, `dictionary_text!/1`, `extract_al/1`, `extract_al_scan/1`, `load_runtime/0`, `load_runtime/1`, `load_runtime!/0`, `load_runtime!/1`, `normalize_al/1`, `parse_al/1`, `plan/2`, `plan/3`, `plan_chain/2`, `plan_chain/3`, `plan_json/2`, `plan_request/2`, `reload_registry/2`, `render_al_prompt/1`, `render_al_prompt/2`, `start_link/0`, `start_link/1`, `validate_al/1`, `version/0`
- `SpectreKinetic.Action`
  - functions: `error/2`, `error/3`, `from_plan/2`, `from_plan/3`
- `SpectreKinetic.ActionChain`
  - functions: `count/1`, `new/1`, `ok_actions/1`
- `SpectreKinetic.Adapter.Server`
  - functions: `action_count/1`, `action_definitions/1`, `add_action/2`, `child_spec/1`, `delete_action/2`, `plan/2`, `plan/3`, `plan_json/2`, `plan_request/2`, `reload_registry/2`, `start_link/0`, `start_link/1`
- `SpectreKinetic.Artifact`
  - functions: `decode_term/1`, `decode_term/2`, `read_json/1`, `read_json/2`, `read_term/1`, `read_term/2`
- `SpectreKinetic.Classifier`
  - callbacks: `call/2`, `init/1`
- `SpectreKinetic.ClassifierPipeline`
  - functions: `init_specs/1`, `run/2`
- `SpectreKinetic.ClassifierPipeline.Spec`
  - struct fields: `module`, `state`
- `SpectreKinetic.Classifiers.BuiltIn`
  - functions: `all/0`, `fetch/1`, `fetch!/1`, `ids/0`
- `SpectreKinetic.Classifiers.PlanConfidence`
  - functions: `build_model/1`, `classifier_id/0`, `feature_dim/0`, `feature_names/0`, `heuristic_confidence/1`
- `SpectreKinetic.Classifiers.PlanConfidence.Features`
  - functions: `build/1`, `dim/0`, `feature_names/0`
- `SpectreKinetic.Classifiers.PlanConfidence.Trainer`
  - functions: `train/2`
- `SpectreKinetic.Classifiers.SafetyRisk`
  - functions: `build_model/1`, `classifier_id/0`, `feature_dim/0`, `feature_names/0`, `hard_guard_risk/1`, `labels/0`, `rule_feature_scores/1`
- `SpectreKinetic.Classifiers.SafetyRisk.Features`
  - functions: `build/1`, `dim/0`, `feature_names/0`, `risk_text/1`
- `SpectreKinetic.Classifiers.SafetyRisk.Trainer`
  - functions: `train/2`
- `SpectreKinetic.Classifiers.SlotConfidence`
  - functions: `build_model/1`, `classifier_id/0`, `feature_dim/0`, `feature_names/0`, `heuristic_slot_confidence/2`
- `SpectreKinetic.Classifiers.SlotConfidence.Features`
  - functions: `build/2`, `dim/0`, `exact_or_alias_source/2`, `feature_names/0`, `type_shape_match?/2`
- `SpectreKinetic.Classifiers.SlotConfidence.Trainer`
  - functions: `train/2`
- `SpectreKinetic.Dictionary`
  - functions: `build/0`, `build/1`, `build!/0`, `build!/1`, `text/0`, `text/1`, `text!/0`, `text!/1`, `to_text/1`
- `SpectreKinetic.Extractor`
  - functions: `extract/1`, `scan/1`
- `SpectreKinetic.Parser`
  - functions: `args/1`, `normalize/1`, `parse/1`, `slot_map/1`, `validate/1`
- `SpectreKinetic.PlanContext`
  - functions: `add_warning/2`, `args/1`, `from_planner_result/4`, `missing_fields/1`, `normalized_al/1`, `parsed_args/1`, `put_classifier_result/3`, `ranked_tools/1`, `scores/1`, `selected_action/1`, `selected_tool/1`, `to_planner_result/1`
- `SpectreKinetic.PlanFinalizer`
  - functions: `to_action/5`
- `SpectreKinetic.Planner`
- `SpectreKinetic.Planner.Compiler`
  - functions: `compile/1`
- `SpectreKinetic.Planner.EmbeddingRuntime`
  - functions: `child_spec/1`, `dim/0`, `dim/1`, `embed/1`, `embed/2`, `embed_batch/1`, `embed_batch/2`, `load/1`, `start_link/0`, `start_link/1`
- `SpectreKinetic.Planner.Registry`
  - functions: `build_tool_card/1`, `normalize_action/1`
  - callbacks: `action_count/1`, `add_action/2`, `all_actions/1`, `close/1`, `delete_action/2`, `embedding_matrix/1`, `get_action/2`, `load_compiled/2`, `load_json/2`, `new/1`, `new_staging/2`, `owner/1`, `put_embedding/3`, `resolve_alias/2`, `tool_cards/1`, `upsert_action/3`
- `SpectreKinetic.Planner.Registry.ETS`
- `SpectreKinetic.Planner.RegistryStore`
  - functions: `action_count/0`, `action_count/1`, `add_action/1`, `add_action/2`, `all_actions/0`, `all_actions/1`, `child_spec/1`, `delete_action/1`, `delete_action/2`, `embedding_matrix/0`, `embedding_matrix/1`, `get_action/1`, `get_action/2`, `load_compiled/1`, `load_compiled/2`, `load_json/1`, `load_json/2`, `put_embedding/2`, `put_embedding/3`, `resolve_alias/1`, `resolve_alias/2`, `start_link/0`, `start_link/1`, `tool_cards/0`, `tool_cards/1`
- `SpectreKinetic.Planner.Retrieval`
  - functions: `options/1`, `retrieve/2`
- `SpectreKinetic.Planner.Runtime`
  - functions: `action_count/1`, `action_definitions/1`, `add_action/2`, `classifiers/1`, `classifiers/2`, `close/1`, `delete_action/2`, `load/0`, `load/1`, `load!/0`, `load!/1`, `plan_opts/1`, `plan_opts/2`, `reload_registry/2`
- `SpectreKinetic.Planner.Runtime.Embeddings`
  - functions: `embed_loaded_registry/2`, `prepare_action/2`, `reembed_after_reload/2`, `reembed_after_reload?/2`
- `SpectreKinetic.Planner.Scorer`
  - functions: `alias_overlap/2`, `cosine_similarity/2`, `fuse_scores/1`, `lexical_overlap/2`, `shape_score/2`, `top_k/2`
- `SpectreKinetic.Planner.Selection`
  - functions: `options/1`, `select/4`
- `SpectreKinetic.Planner.SlotMapper`
  - functions: `detect_value_type/1`, `map_slots/2`
- `SpectreKinetic.Prompt`
  - functions: `build/0`, `build/1`, `build!/0`, `build!/1`, `render/1`, `render/2`
- `SpectreKinetic.Reranker.Calibration`
  - functions: `build/1`, `build/2`
- `SpectreKinetic.Reranker.FeatureBuilder`
  - functions: `build_matrix/2`, `build_matrix/3`, `feature_dim/1`
- `SpectreKinetic.Reranker.Runtime`
  - functions: `load/1`, `score/3`, `score_batch/2`
- `SpectreKinetic.Reranker.Runtime.Axon`
- `SpectreKinetic.Reranker.Trainer`
- `SpectreKinetic.RuntimeConfig`
  - functions: `built_in_plan_defaults/0`, `default_plan_options/0`, `missing_path_message/1`, `normalize_request/1`, `resolve_optional_path/4`, `resolve_required_path/4`, `resolve_runtime_paths/0`, `resolve_runtime_paths/1`, `stringify_map/1`, `validate_options/1`, `validate_plan_input/2`, `validate_request/1`
- `SpectreKinetic.Server`
- `SpectreKinetic.Tool`
- `SpectreKinetic.Tool.Extractor`
  - functions: `extract_app/1`, `extract_module/1`, `extract_modules/1`
