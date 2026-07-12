# Piano di hardening di Spectre Kinetic

Branch: `agent/kinetic-hardening`

Stato aggiornato: 2026-07-12. Una voce marcata `[x]` è implementata nel
branch; i comandi Mix restano volutamente da eseguire nell'ambiente dell'autore.

Obiettivo: rendere il planner sicuro da usare come fondazione per Spectre e per il futuro protocollo Pulse, mantenendo Kinetic come livello di selezione e validazione dei tool, senza esecuzione diretta.

## Regole del lavoro

- Un commit per problema o gruppo atomico di problemi strettamente collegati.
- Nessun tool viene eseguito da Kinetic: il risultato resta una proposta dati.
- Le decisioni di sicurezza sono monotone: una fase successiva non può trasformare `rejected`, `needs_confirmation` o `needs_clarification` in `ok`.
- Registry e artifact vengono validati completamente prima di diventare attivi.
- Le API pubbliche restituiscono errori strutturati invece di far cadere il server.
- Nessun atom viene creato da input runtime non affidabile.

## Fase 1 — correttezza e sicurezza P0

- [x] Rendere `reload_registry/2` transazionale tramite backend staged e swap atomico.
- [x] Rendere `add_action/2`, sostituzione e delete coerenti con alias ed embedding derivati.
- [x] Esplicitare ownership e chiusura delle risorse ETS; aggiungere `close_runtime/1`.
- [x] Impedire alla repair finale degli argomenti di cancellare una decisione dei classifier.
- [x] Applicare `reranker_threshold` senza bypassare `tool_threshold` e fallire chiuso su output/errori ambigui.
- [ ] Consumare la calibrazione persistita per scegliere automaticamente la soglia del reranker.
- [x] Validare integralmente request, slot, top-k, soglie e valori numerici al boundary pubblico.
- [x] Applicare realmente `mapping_threshold` e propagare tutte le opzioni fallback documentate.

## Fase 2 — artifact e registry affidabili

- [x] Usare decoding ETF sicuro e limiti di dimensione ed espansione compressa.
- [x] Versionare il compiled registry con dimensione/dtype e produrre un manifest encoder con identità, revisione e checksum.
- [ ] Collegare manifest encoder e compiled registry con dimensione, identità e checksum incrociati.
- [x] Validare separatamente schema e compatibilità interna degli artifact di classifier, reranker e registry prima dell'attivazione.
- [ ] Validare in modo incrociato la compatibilità fra tutti gli artifact caricati insieme.
- [x] Rendere scrittura e download atomici con file temporaneo e rename.
- [x] Rendere i download riproducibili tramite revision/versione e checksum.
- [x] Validare schema dei tool: id, arity, argomenti, alias ed esempi.
- [ ] Aggiungere una allowlist applicativa opzionale per autorizzare le MFA dichiarate.

## Fase 3 — runtime e performance

- [x] Risolvere config/env path prima del caricamento e fallire su registry vuoto non intenzionale.
- [ ] Definire un behaviour pubblico per embedding provider locali o remoti.
- [ ] Permettere l'iniezione di un provider supervisionato, incluso OpenRouter.
- [ ] Condividere l'encoder tra retrieval e reranker.
- [ ] Cacheare matrice embedding, id vector e card lessicali per registry generation.
- [x] Mantenere il runtime library-first fuori da un singolo GenServer di inferenza.
- [ ] Parallelizzare o rendere concorrente il planning nell'adapter supervisionato.
- [x] Rendere esplicito il lifecycle e la chiusura delle risorse runtime.
- [ ] Aggiungere timeout configurabili ed eliminare le attese `:infinity` residue.

## Fase 4 — qualità del planning e training

- [x] Validare e convertire gli argomenti usando il tipo dichiarato dal tool.
- [x] Restituire ambiguità quando più mapping/tool hanno score troppo vicini.
- [x] Configurare esplicitamente la semantica dell'output ONNX del reranker.
- [x] Validare hyperparameter e dataset; impedire batch size/epoch/dimensioni non positive.
- [ ] Aggiungere holdout, metriche, confusion matrix e calibrazione consumata dal runtime.
- [x] Rimuovere `chain_classifiers`; Directive resta proprietario del workflow.
- [x] Aggiungere limiti di dimensione e complessità agli input AL/JSON/slot.
- [ ] Aggiungere test fuzz/property al parser AL.

## Fase 5 — packaging e automazione

- [ ] Separare il percorso planner leggero dalle dipendenze ML/training quando possibile.
- [x] Dichiarare direttamente tutte le dipendenze realmente usate.
- [x] Risolvere dataset bundled con `:code.priv_dir(:spectre_kinetic)`.
- [ ] Namespace coerente per tutti i Mix task.
- [ ] Aggiungere ExDoc, changelog e aliases di verifica.
- [x] Aggiungere workflow GitHub separati per test, Credo e Dialyzer.
- [x] Eseguire i workflow automaticamente su `push` a `master`, senza evento `pull_request`.
- [x] Permettere `workflow_dispatch` separato per test, Credo e Dialyzer.

Nota operativa: per rendere `push` a `master` equivalente a "solo dopo merge",
il repository deve vietare i push diretti tramite branch protection/ruleset.

## Validazione richiesta

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`
- [ ] `mix credo --strict`
- [ ] `mix dialyzer`
- [x] Parsing statico di tutti i 102 file Elixir senza errori di sintassi.
- [x] Parsing YAML dei workflow e `git diff --check` senza errori.

## Copertura di regressione aggiunta (non eseguita localmente)

- [x] Test di failure atomicity per registry reload/add.
- [x] Test di ownership e shutdown delle risorse.
- [x] Test di concorrenza e locking del downloader.
- [ ] Suite completa di concorrenza per planning e runtime supervisionato.
- [x] Test che una safety decision non possa essere promossa a `ok`.
- [x] Test che reranker e mapping rispettino le soglie.
- [x] Test artifact corrotti, incompatibili e sovradimensionati.

Nota: l'ambiente locale corrente non include Erlang, Elixir o Mix. L'esecuzione
dei controlli Elixir è lasciata all'autore; i workflow sono pronti sul branch e
diventeranno avviabili manualmente dall'interfaccia GitHub dopo il merge sul
default branch.
