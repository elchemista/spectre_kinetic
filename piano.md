# Piano di hardening di Spectre Kinetic

Branch: `agent/kinetic-hardening`

Obiettivo: rendere il planner sicuro da usare come fondazione per Spectre e per il futuro protocollo Pulse, mantenendo Kinetic come livello di selezione e validazione dei tool, senza esecuzione diretta.

## Regole del lavoro

- Un commit per problema o gruppo atomico di problemi strettamente collegati.
- Nessun tool viene eseguito da Kinetic: il risultato resta una proposta dati.
- Le decisioni di sicurezza sono monotone: una fase successiva non può trasformare `rejected`, `needs_confirmation` o `needs_clarification` in `ok`.
- Registry e artifact vengono validati completamente prima di diventare attivi.
- Le API pubbliche restituiscono errori strutturati invece di far cadere il server.
- Nessun atom viene creato da input runtime non affidabile.

## Fase 1 — correttezza e sicurezza P0

- [ ] Rendere `reload_registry/2` transazionale tramite backend staged e swap atomico.
- [ ] Rendere `add_action/2`, sostituzione e delete coerenti con alias ed embedding derivati.
- [ ] Esplicitare ownership e chiusura delle risorse ETS; aggiungere `close_runtime/1`.
- [ ] Impedire alla repair finale degli argomenti di cancellare una decisione dei classifier.
- [ ] Applicare una soglia calibrata al reranker senza bypassare `tool_threshold`.
- [ ] Validare integralmente request, slot, top-k, soglie e valori numerici al boundary pubblico.
- [ ] Applicare realmente `mapping_threshold` e propagare tutte le opzioni fallback documentate.

## Fase 2 — artifact e registry affidabili

- [ ] Usare decoding ETF sicuro e limiti di dimensione.
- [ ] Aggiungere manifest con schema version, model identity, dimensions e checksum.
- [ ] Verificare compatibilità di classifier, reranker e registry prima dell'attivazione.
- [ ] Rendere scrittura e download atomici con file temporaneo e rename.
- [ ] Rendere i download riproducibili tramite revision/versione e checksum.
- [ ] Validare schema dei tool: id, MFA autorizzata, arity, argomenti, alias ed esempi.

## Fase 3 — runtime e performance

- [ ] Risolvere config/env path prima del caricamento e fallire su registry vuoto non intenzionale.
- [ ] Definire un behaviour pubblico per embedding provider locali o remoti.
- [ ] Permettere l'iniezione di un provider supervisionato, incluso OpenRouter.
- [ ] Condividere l'encoder tra retrieval e reranker.
- [ ] Cacheare matrice embedding, id vector e card lessicali per registry generation.
- [ ] Evitare che un singolo GenServer serializzi tutta l'inferenza; mantenere serializzate solo le mutazioni.
- [ ] Aggiungere timeout configurabili e lifecycle esplicito.

## Fase 4 — qualità del planning e training

- [ ] Validare e convertire gli argomenti usando il tipo dichiarato dal tool.
- [ ] Restituire ambiguità quando più mapping/tool hanno score troppo vicini.
- [ ] Configurare esplicitamente la semantica dell'output ONNX del reranker.
- [ ] Validare hyperparameter e dataset; impedire batch size/epoch/dimensioni non positive.
- [ ] Aggiungere holdout, metriche, confusion matrix e calibrazione consumata dal runtime.
- [ ] Rimuovere o implementare `chain_classifiers`; Directive deve restare proprietario del workflow.
- [ ] Aggiungere limiti input e test fuzz/property al parser AL.

## Fase 5 — packaging e automazione

- [ ] Separare il percorso planner leggero dalle dipendenze ML/training quando possibile.
- [ ] Dichiarare direttamente tutte le dipendenze realmente usate.
- [ ] Risolvere dataset bundled con `:code.priv_dir(:spectre_kinetic)`.
- [ ] Namespace coerente per tutti i Mix task.
- [ ] Aggiungere ExDoc, changelog e aliases di verifica.
- [ ] Aggiungere workflow GitHub per test, Credo e Dialyzer.
- [ ] Eseguire i workflow automaticamente solo dopo merge/push su `master`.
- [ ] Permettere `workflow_dispatch` separato per test, Credo e Dialyzer.

## Validazione richiesta

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`
- [ ] `mix credo --strict`
- [ ] `mix dialyzer`
- [ ] Test di failure atomicity per registry reload/add.
- [ ] Test di ownership, shutdown e concorrenza.
- [ ] Test che una safety decision non possa essere promossa a `ok`.
- [ ] Test che reranker e mapping rispettino le soglie.
- [ ] Test artifact corrotti, incompatibili e sovradimensionati.

Nota: l'ambiente locale corrente non include Erlang, Elixir o Mix. I controlli Elixir saranno eseguiti dai workflow GitHub; localmente vengono comunque verificati diff, struttura, whitespace e cronologia dei commit.
