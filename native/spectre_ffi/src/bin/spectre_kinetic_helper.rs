use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::collections::{HashMap, HashSet};
use std::path::Path;

#[derive(Parser)]
#[command(
    name = "spectre-kinetic-helper",
    version,
    about = "Helper CLI used by the spectre_kinetic Elixir mix tasks"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Train {
        #[arg(long)]
        teacher_onnx: String,
        #[arg(long)]
        tokenizer: String,
        #[arg(long)]
        corpus: String,
        #[arg(long)]
        out: String,
        #[arg(long, default_value = "256")]
        max_len: usize,
        #[arg(long, default_value = "384")]
        dim: usize,
        #[arg(long)]
        zipf: bool,
    },
    BuildRegistry {
        #[arg(long)]
        model: String,
        #[arg(long)]
        registry: String,
        #[arg(long)]
        out: String,
    },
    ExtractDict {
        #[arg(long)]
        corpus: String,
        #[arg(long)]
        registry: Option<String>,
        #[arg(long)]
        seed: Option<String>,
        #[arg(long, default_value = "DICTIONARY.txt")]
        out: String,
        #[arg(long, default_value = "500")]
        top_n: usize,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.cmd {
        Commands::Train {
            teacher_onnx,
            tokenizer,
            corpus,
            out,
            max_len,
            dim,
            zipf,
        } => cmd_train(&teacher_onnx, &tokenizer, &corpus, &out, max_len, dim, zipf),
        Commands::BuildRegistry {
            model,
            registry,
            out,
        } => cmd_build_registry(&model, &registry, &out),
        Commands::ExtractDict {
            corpus,
            registry,
            seed,
            out,
            top_n,
        } => cmd_extract_dict(&corpus, registry.as_deref(), seed.as_deref(), &out, top_n),
    }
}

fn cmd_train(
    teacher_onnx: &str,
    tokenizer_path: &str,
    corpus_path: &str,
    out_dir: &str,
    max_len: usize,
    dim: usize,
    apply_zipf: bool,
) -> Result<()> {
    eprintln!("Loading teacher ONNX model...");
    let mut teacher = spectre_train::TeacherModel::load(Path::new(teacher_onnx))
        .context("failed to load teacher model")?;

    eprintln!("Teacher dim: {}", teacher.dim());

    eprintln!("Parsing corpus...");
    let corpus =
        spectre_train::parse_corpus(Path::new(corpus_path)).context("failed to load corpus")?;
    eprintln!("Corpus entries: {}", corpus.len());

    let tokenizer = tokenizers::Tokenizer::from_file(tokenizer_path)
        .map_err(|e| anyhow::anyhow!("failed to load tokenizer: {e}"))?;

    let config = spectre_train::DistillConfig {
        max_len,
        dim,
        apply_zipf,
        ..Default::default()
    };

    eprintln!("Distilling embeddings...");
    let result = spectre_train::distill(&mut teacher, &tokenizer, &corpus, &config)
        .context("distillation failed")?;
    eprintln!("  vocab_size={}, dim={}", result.vocab_size, result.dim);

    let metadata = spectre_core::types::PackMetadata {
        teacher_id: teacher_onnx.to_string(),
        dim: result.dim,
        pooling: "mean".to_string(),
        tokenizer_hash: format!("{:x}", simple_hash(tokenizer_path)),
        max_len,
        apply_pca: None,
        apply_zipf: if apply_zipf { Some(true) } else { None },
    };

    eprintln!("Writing pack to {out_dir}...");
    spectre_train::write_pack(
        Path::new(out_dir),
        &metadata,
        Path::new(tokenizer_path),
        &result,
    )
    .context("failed to write pack")?;

    eprintln!("Done.");
    Ok(())
}

fn cmd_build_registry(model_dir: &str, registry_path: &str, out_path: &str) -> Result<()> {
    eprintln!("Loading model pack...");
    let (meta, embedder) =
        spectre_core::pack::load_pack(Path::new(model_dir)).context("failed to load model pack")?;

    eprintln!("Loading tool registry...");
    let registry_json =
        std::fs::read_to_string(registry_path).context("failed to read registry JSON")?;
    let registry: spectre_core::types::ToolRegistry =
        serde_json::from_str(&registry_json).context("failed to parse registry JSON")?;
    eprintln!("  {} actions loaded", registry.actions.len());

    eprintln!("Building compiled registry...");
    let compiled =
        spectre_core::registry::build_registry(&embedder, &registry, &meta.tokenizer_hash)
            .context("failed to build registry")?;

    eprintln!("Saving to {out_path}...");
    compiled
        .save(Path::new(out_path))
        .context("failed to save .mcr")?;

    eprintln!("Done.");
    Ok(())
}

fn cmd_extract_dict(
    corpus_path: &str,
    registry_path: Option<&str>,
    seed_path: Option<&str>,
    out_path: &str,
    top_n: usize,
) -> Result<()> {
    eprintln!("Parsing corpus...");
    let entries =
        spectre_train::parse_corpus(Path::new(corpus_path)).context("failed to load corpus")?;

    let mut upper_counts: HashMap<String, usize> = HashMap::new();
    let mut slot_keys: HashSet<String> = HashSet::new();
    let mut special_upper: HashSet<String> = HashSet::new();
    let mut examples: Vec<String> = Vec::new();
    let mut examples_seen: HashSet<String> = HashSet::new();

    if let Some(path) = seed_path {
        let seed = std::fs::read_to_string(path)
            .with_context(|| format!("failed to read seed file {path}"))?;
        for tok in split_tokens(&seed).into_iter().map(|t| t.to_uppercase()) {
            if tok.len() >= 2 {
                special_upper.insert(tok);
            }
        }
    }

    for entry in entries.iter() {
        match entry {
            spectre_train::CorpusEntry::Al { text }
            | spectre_train::CorpusEntry::ToolDoc { text, .. }
            | spectre_train::CorpusEntry::ToolSpec { text, .. }
            | spectre_train::CorpusEntry::ParamCard { text, .. }
            | spectre_train::CorpusEntry::SlotCard { text }
            | spectre_train::CorpusEntry::Example { text, .. } => {
                for word in split_tokens(text) {
                    let upper = word.to_uppercase();
                    if upper.len() >= 2 && upper.chars().any(|ch| ch.is_ascii_alphabetic()) {
                        *upper_counts.entry(upper).or_insert(0) += 1;
                    }
                }
            }
        }

        if let spectre_train::CorpusEntry::Al { text }
        | spectre_train::CorpusEntry::SlotCard { text }
        | spectre_train::CorpusEntry::Example { text, .. } = entry
        {
            let parsed = spectre_core::al_parser::parse_al(text);
            for slot in parsed.slot_keys {
                if !slot.key.is_empty() {
                    slot_keys.insert(slot.key);
                }
            }

            let example = text.trim();
            if !example.is_empty() && examples_seen.insert(example.to_string()) {
                examples.push(example.to_string());
            }
        }
    }

    if let Some(path) = registry_path {
        eprintln!("Loading registry JSON...");
        let registry_json =
            std::fs::read_to_string(path).context("failed to read registry JSON")?;
        let registry: spectre_core::types::ToolRegistry =
            serde_json::from_str(&registry_json).context("failed to parse registry JSON")?;

        for tool in registry.actions.iter() {
            for part in split_tokens(&tool.module) {
                let upper = part.to_uppercase();
                if upper.len() >= 2 {
                    *upper_counts.entry(upper).or_insert(0) += 1;
                }
            }

            for part in split_tokens(&tool.name) {
                let upper = part.to_uppercase();
                if upper.len() >= 2 {
                    *upper_counts.entry(upper).or_insert(0) += 1;
                }
            }

            for arg in tool.args.iter() {
                if !arg.name.is_empty() {
                    slot_keys.insert(arg.name.to_lowercase());
                }

                for alias in arg.aliases.iter() {
                    if !alias.is_empty() {
                        slot_keys.insert(alias.to_lowercase());
                    }
                }
            }

            for text in tool.examples.iter().chain([&tool.doc, &tool.spec]) {
                for word in split_tokens(text) {
                    let upper = word.to_uppercase();
                    if upper.len() >= 2 && upper.chars().any(|ch| ch.is_ascii_alphabetic()) {
                        *upper_counts.entry(upper).or_insert(0) += 1;
                    }
                }
            }

            for example in tool.examples.iter() {
                let parsed = spectre_core::al_parser::parse_al(example);
                for slot in parsed.slot_keys {
                    if !slot.key.is_empty() {
                        slot_keys.insert(slot.key);
                    }
                }

                let example = example.trim();
                if !example.is_empty() && examples_seen.insert(example.to_string()) {
                    examples.push(example.to_string());
                }
            }
        }
    }

    let mut final_upper: Vec<String> = special_upper.into_iter().collect();
    final_upper.sort();

    let mut freq: Vec<(String, usize)> = upper_counts.into_iter().collect();
    freq.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));

    let mut seen_upper: HashSet<String> = final_upper.iter().cloned().collect();
    for (word, _) in freq.into_iter() {
        if seen_upper.contains(&word)
            || word.len() < 2
            || !word.chars().any(|ch| ch.is_ascii_alphabetic())
        {
            continue;
        }

        final_upper.push(word.clone());
        seen_upper.insert(word);

        if final_upper.len() >= top_n {
            break;
        }
    }

    let mut final_slots: Vec<String> = slot_keys.into_iter().collect();
    final_slots.sort();

    eprintln!("Writing {out_path}...");
    let line1 = final_upper.join(" ");
    let line2 = final_slots.join(" ");
    let line3 = if examples.is_empty() {
        String::new()
    } else {
        examples.join(" | ")
    };
    let output = if line3.is_empty() {
        format!("{line1}\n{line2}\n")
    } else {
        format!("{line1}\n{line2}\n{line3}\n")
    };

    std::fs::write(out_path, output).with_context(|| format!("failed to write {out_path}"))?;
    eprintln!("Done.");
    Ok(())
}

fn simple_hash(input: &str) -> u64 {
    let mut hash: u64 = 5381;
    for byte in input.bytes() {
        hash = hash.wrapping_mul(33).wrapping_add(byte as u64);
    }
    hash
}

fn split_tokens(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();

    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' {
            current.push(ch);
        } else if !current.is_empty() {
            tokens.push(current.clone());
            current.clear();
        }
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}
