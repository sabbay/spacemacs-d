# claude-collab — diagram architektury

Stan po commitach T1.1..T2.3 (Stage 1 anchors + Stage 2 ADT + tx-id +
chokepoint + drift guard wszędzie).

## 1. Warstwy + dependencies

```
                          ┌────────────────────────────────────┐
                          │  AGENT (Claude via MCP)            │
                          │  → JSON-RPC                        │
                          └──────────────┬─────────────────────┘
                                         │
   ╔═════════════════════════════════════╪══════════════════════════════╗
   ║ MCP BOUNDARY  (mcp-server-emacs-tools — narzędzia rejestrowane    ║
   ║                w runtime z claude-collab--mcp-* handlerami)       ║
   ╚═════════════════════════════════════╪══════════════════════════════╝
                                         │
                       ┌─────────────────┴──────────────┐
                       │                                │
                       ▼                                ▼
             ┌──────────────────┐            ┌──────────────────────┐
             │  edit tools      │            │  meta / read tools   │
             │ • apply-edit     │            │ • list-annotations   │
             │ • apply-annotation│           │ • get-region-bounds  │
             │ • apply-batch    │            │ • check-anchor       │
             │ • resolve        │            │ • get-active-plan    │
             └────────┬─────────┘            │ • run-tests          │
                      │                       └────────┬─────────────┘
                      │                                │
                      ▼                                ▼
   ╔═════════════════════════════════════════════════════════════════╗
   ║  ADAPTER  (lisp/claude-collab.el — buffers, files, overlays,    ║
   ║            org-remark side effects, MCP telemetry, transient)   ║
   ╠═════════════════════════════════════════════════════════════════╣
   ║                                                                 ║
   ║   ┌───────────────────────────┐   ┌──────────────────────────┐  ║
   ║   │ APPLY pipeline             │   │ ANNOTATION lifecycle     │  ║
   ║   │ • apply-annotation         │   │ • create-highlight       │  ║
   ║   │   → drift guard            │   │     ↑ chokepoint (T2.2)  │  ║
   ║   │   → edit-region            │   │ • add-annotation         │  ║
   ║   │   → resolve-by-id          │   │ • resolve-by-id          │  ║
   ║   │   → rollback on resolve-err│   │   captures ctx + text    │  ║
   ║   │ • apply-edit (raw, drift?) │   │ • unresolve-annotation   │  ║
   ║   │ • apply-batch              │   │   strict drift check T2.3│  ║
   ║   └───────────────┬────────────┘   └────────────┬─────────────┘  ║
   ║                   │                              │                ║
   ║                   └──────────┬───────────────────┘                ║
   ║                              │                                   ║
   ║                              ▼                                   ║
   ║             ┌────────────────────────────────┐                   ║
   ║             │ SESSION recording              │                   ║
   ║             │ • --log-edit (canonical, only) │                   ║
   ║             │ • tx-id grouping (T2.1)        │                   ║
   ║             │ • edit ADT: text | resolve     │                   ║
   ║             │ • revert-edit pcase dispatch   │                   ║
   ║             └────────────────┬───────────────┘                   ║
   ║                              │                                   ║
   ║                              ▼                                   ║
   ║             ┌────────────────────────────────┐                   ║
   ║             │ MCP TELEMETRY (JSONL)          │                   ║
   ║             │ • --with-mcp-log (macro)       │                   ║
   ║             │ • --mcp-log-entry → file tee   │                   ║
   ║             │ • size-cap rotation            │                   ║
   ║             └────────────────────────────────┘                   ║
   ║                                                                 ║
   ╚════════════════════════════════════╪════════════════════════════╝
                                        │
                                        ▼
   ╔═════════════════════════════════════════════════════════════════╗
   ║  PURE CORE  (lisp/claude-collab-core.el — 297 lines)            ║
   ║  side-effect-free, batch-testable from string + struct           ║
   ╠═════════════════════════════════════════════════════════════════╣
   ║                                                                 ║
   ║   ┌────────────────────┐   ┌──────────────────────────────┐     ║
   ║   │ Anchor model        │   │ Algorithms                   │     ║
   ║   │ • core-anchor       │   │ • locate-anchor              │     ║
   ║   │   text+ctx-before   │   │   → :ok / :not-found /       │     ║
   ║   │   +ctx-after        │   │     :ambiguous               │     ║
   ║   │ • core-region       │   │ • detect-drift               │     ║
   ║   │   begin..end        │   │   → :clean / :drifted        │     ║
   ║   └────────────────────┘   │ • normalize-action / -unit   │     ║
   ║                            │ • core-prin1 (no truncation) │     ║
   ║                            │ • batch-edit-arg (json shapes)│    ║
   ║                            └──────────────────────────────┘     ║
   ╚═════════════════════════════════════════════════════════════════╝

                                        │
                                        ▼
   ╔═════════════════════════════════════════════════════════════════╗
   ║  STATE                                                          ║
   ╠═════════════════════════════════════════════════════════════════╣
   ║   in-memory                          on-disk                    ║
   ║   ┌───────────────────────┐          ┌──────────────────────┐   ║
   ║   │ --sessions hash       │          │ marginalia.org       │   ║
   ║   │   sid → list<edit>    │          │   :id, :text,        │   ║
   ║   │ --known-annot-ids hash│          │   :context-before,   │   ║
   ║   │   id  → file          │          │   :context-after,    │   ║
   ║   │ --current-tx-id       │          │   :label             │   ║
   ║   │ --active-plan-file    │          │ source files (.org)  │   ║
   ║   └───────────────────────┘          │ .claude-collab.log   │   ║
   ║                                      │   .jsonl (capped 50M)│   ║
   ║                                      └──────────────────────┘   ║
   ╚═════════════════════════════════════════════════════════════════╝
```

## 2. Edit ADT (po Stage 2)

```
                claude-collab-edit  (base, slots: session-id, buffer,
                       │              buffer-name, begin, end,
                       │              before-text, after-text,
                       │              timestamp, overlay, tx-id)
                       │
        ┌──────────────┴──────────────┐
        │                             │
        ▼                             ▼
 claude-collab-edit-text     claude-collab-edit-resolve
    (replace/insert/delete)     (annotation-data:
                                  :id :file :begin :end
                                  :text :label
                                  :context-before
                                  :context-after)

 revert via:                  unresolve via:
   delete-region+insert         strict drift check on text
   (raw)                        then --create-highlight chokepoint
```

`pcase` w `--revert-edit` / `--diff-summary`:

```
(pcase edit
  ((pred edit-text-p)    → text-revert)
  ((pred edit-resolve-p) → unresolve-annotation)
  (_                     → signal claude-collab-conflict
                            "Unknown edit variant"))   ← T1.3 testowane
```

## 3. Happy path: `apply-annotation :replace`

```
agent: { tool: "apply-annotation", id: "abc", action: "replace", new-text: "X" }
   │
   ▼
mcp-apply-annotation (handler)
   │
   ▼  with-mcp-log "apply-annotation" args
apply-annotation
   │
   │ 1. find-annotation id  → (buf . overlay) | nil
   │ 2. pre-edit-fingerprint:
   │       overlay bounds, recorded text,
   │       core-anchor-from-marginalia → core-detect-drift
   │       → :clean | (:drifted :reason :diagnosis)
   │ 3. drift? abort: (:error :code :drift :drift-diag PLIST)
   │
   │ 4. compute region (unit-aware: :annotation/:line/:paragraph/...)
   │ 5. snapshot revert-before-text (per-action policy)
   │ 6. --edit-region buf beg end new-text
   │       │
   │       │ A. before-change: --log-edit pushes claude-collab-edit-text
   │       │      (with tx-id from --current-tx-id, nil if direct call)
   │       │ B. delete-region + insert
   │       │ C. save-buffer
   │       └──> session record updated
   │
   │ 7. resolve-annotation-by-id id
   │       │ — reads marginalia ctx-before/ctx-after BEFORE delete
   │       │ — pushes claude-collab-edit-resolve onto session
   │       │ — org-remark deletes the highlight overlay+marginalia
   │       │
   │       └─ throws? → ROLLBACK:
   │                     delete new-text region, re-insert revert-before-text
   │                     return (:error :code :resolve-failed :resolve-error ...)
   │
   ▼
return (:ok t :new-begin N :new-end M :resolved t :pre-edit ...)
   │
   ▼  --mcp-log-entry tees JSONL line { tool, args, result, elapsed-ms }
agent receives result
```

## 4. Revert flow: `revert-session`

```
session-edits sid → list of edits in chronological order
   │
   ▼
walk reversed:
   for each edit:
     pcase edit
       (pred edit-text-p)    → delete new-text region; re-insert before-text
       (pred edit-resolve-p) → --unresolve-annotation:
                                 ▶ verify buffer text matches recorded :text  (T2.3)
                                 ▶ mismatch? signal claude-collab-conflict
                                              → caller offers ediff
                                 ▶ match?    → --create-highlight (chokepoint)
                                              re-applies label + context props
       (_)                   → signal claude-collab-conflict "Unknown edit variant"
   │
   ▼
session record cleared on success
```

## 5. Telemetry granularity (po T2.1)

```
agent invokes eval-elisp (which contains 3× apply-edit calls)
   │
   ▼
--advise-eval-elisp:
   let claude-collab--current-tx-id = "tx-N"   ← bumped per eval-elisp call
   ▼
 each apply-edit:
   --log-edit reads --current-tx-id → stamps onto edit struct
   --with-mcp-log macro emits JSONL line including (tx_id . "tx-N")
   ▼
JSONL log:
   {"ts":..., "tool":"eval-elisp",      "tx_id":"tx-7", ...}
   {"ts":..., "tool":"apply-edit",      "tx_id":"tx-7", ...}
   {"ts":..., "tool":"apply-edit",      "tx_id":"tx-7", ...}
   {"ts":..., "tool":"apply-edit",      "tx_id":"tx-7", ...}

direct mcp-apply-edit (not under eval-elisp):
   --current-tx-id is nil → tx_id field is null in JSONL
   each call still gets its own session record
```

## 6. Co usunięte vs co zostało

```
PRZED Option-B / Stage-2:                 PO:
─────────────────────────────             ──────────────────────────────
--record-advice on safe-eval         →   USUNIĘTE (T2.1)
--inside-safe-eval flag              →   USUNIĘTE (T2.1)
before-change-functions diff snap    →   USUNIĘTE — per-edit log canonical
:ok t :resolved nil  (półstan)       →   USUNIĘTE — transakcja: ok|rollback
two paths to org-remark-highlight... →   ONE chokepoint --create-highlight
unresolve replays at stored bytes    →   strict drift check first (T2.3)
check-anchor :exists nil             →   :reason :buffer-not-open|:unknown-id
--mcp-log-suppress (telemetria)      →   ZOSTAJE — ortogonalne do tx-id
claude-collab-conflict define-error  →   ZOSTAJE — wykorzystywane szerzej
```

## 7. Test surface

```
lisp/claude-collab-test.el — 112 testów, 0 skipped
├── core-* (16)          pure algorithms (locate, drift, normalize)
├── apply-edit-* (15)    raw apply + drift guard
├── apply-annotation-*   transactional rollback paths
├── apply-batch-* (4)    multi-edit atomicity
├── resolve-* / unresolve-* (10)
│    ├── unresolve-aborts-on-drift              (T2.3)
│    ├── unresolve-clean-when-region-unchanged  (T2.3)
│    └── unresolve-preserves-anchor-context     (T2.2)
├── check-anchor-* (8)   buffer-closed/overlay-collapsed/anchor-missing  (T1.1)
├── mcp-log-* (6)        JSONL shape, file tee, already-resolved          (T1.2)
├── revert-edit-* / diff-summary-* (4)  pcase fallback                    (T1.3)
├── tx-id-* (3)          eval-elisp grouping, direct call, always-logs    (T2.1)
└── create-highlight-* (2)  chokepoint coverage                           (T2.2)
```

## 8. Co świadomie poza zakresem

- **Stage 3** — source-as-projection (event sourcing). Plik byłby autorytetywny, sesja
  to log eventów. Nie ma bólu uzasadniającego, więc deferred.
- **Migracja pure-core do TS/Python** — sensowne dopiero gdy >1500 linii lub
  cross-editor. Teraz: 297 linii, jeden edytor.
- **Fuzzy anchor fallback** (Levenshtein) — strict-match catch'uje całą
  klasę drift. Fuzzy add'uje confidence, którego dziś nie potrzebujemy.
