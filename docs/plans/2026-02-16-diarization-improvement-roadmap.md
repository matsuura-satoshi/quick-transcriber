# Speaker Diarization Improvement Roadmap

## Background

### Current Performance (CALLHOME, 5 conversations each)

**Direct chunks (no accumulation):**

| Chunk | EN Accuracy | EN Flips | JA Accuracy | JA Flips | Speaker Count Acc |
|-------|------------|----------|-------------|----------|-------------------|
| 3s    | 0.612      | 46.2     | 0.615       | 63.8     | EN:0.6 / JA:0.6   |
| 5s    | 0.685      | 23.8     | 0.670       | 27.4     | EN:0.8 / JA:0.8   |
| 7s    | 0.777      | 9.0      | 0.685       | 14.0     | EN:0.6 / JA:0.8   |

**Accumulation mode (input chunk + 7s internal accumulation, window=15s):**

| Input Chunk | EN Accuracy | EN Flips | JA Accuracy | JA Flips |
|------------|------------|----------|-------------|----------|
| 3s + 7s    | 0.721      | 5.2      | 0.629       | 11.4     |
| 5s + 7s    | **0.793**  | **5.6**  | 0.657       | 13.4     |

### Key Findings

- 3s→5s: Large jump in accuracy (EN +7.3pp, JA +5.5pp), flips halved
- 5s→7s: Further improvement but diminishing returns
- 5s+7s accumulation achieves best EN score (0.793), surpassing direct 7s (0.777)
- 5s latency is acceptable in practice (user-confirmed)

### Decision: Default chunkDuration 3s → 5s

`TranscriptionParameters.chunkDuration` default changes from 3.0 to 5.0.

### Structural Constraints (unchanged)

- Real-time processing (5s transcription latency)
- FluidAudio embedding model (pyannote-based, 256-dim) is external dependency
- On-device processing (privacy requirement)

### SOTA Context

- Offline SOTA: 8.8-10.7% DER (full audio, bidirectional)
- Real-time SOTA: 15-20% DER (few seconds latency)
- Current system: ~21% chunk error rate (EN, 5s+7s) is reasonable for real-time 5s constraint

## Roadmap

### Phase 0: AMI Dataset Validation

**Goal:** Quantify performance on realistic meeting audio (3-5 speakers) vs CALLHOME (2-speaker phone calls).

**Tasks:**
1. Add AMI Meeting Corpus download to `Scripts/download_datasets.py`
   - Source: HuggingFace `edinburghcstr/ami` (headsetmix audio + annotations)
   - Output: `~/Documents/QuickTranscriber/test-audio/ami/`
2. Add AMI benchmark tests to `DiarizationBenchmarkTests`
   - Test: 5s direct, 5s+7s accumulation, window 15s/30s
3. Analyze: accuracy degradation from 2→3-5 speakers, speakerCountAccuracy

**Expected Insights:**
- Multi-speaker accuracy baseline
- Whether `expectedSpeakerCount` (Phase 1) is critical for meetings
- Inform Phase C algorithm decisions

### Phase 1: Expected Speaker Count

**Goal:** Eliminate speaker over-detection with minimal implementation cost.

**Problem:** `EmbeddingBasedSpeakerTracker` registers new speakers when cosine similarity < 0.5, even if caused by noise or voice variation. This creates phantom speakers.

**Implementation:**
1. Add `expectedSpeakerCount: Int?` to `TranscriptionParameters` (nil = unlimited, default)
2. In `EmbeddingBasedSpeakerTracker.identify()`: when profile count reaches `expectedSpeakerCount`, assign to most similar existing speaker instead of registering new
3. Settings UI: "Number of Speakers" picker (Auto / 2 / 3 / 4 / 5)
4. Benchmark: measure effect with correct speaker count vs Auto

**Expected Effect:**
- Speaker over-detection eliminated
- Accuracy improvement from forced assignment to existing speakers
- Very small implementation cost (single conditional in `identify()`)

### Phase 2: Speaker Enrollment (Cross-Session Memory)

**Goal:** Remember speakers across sessions. Start with known voice profiles instead of building from scratch.

**Architecture:**

```
SpeakerProfile (persisted)
  ├─ id: UUID
  ├─ name: String ("Tanaka", "Alice", etc.)
  ├─ embedding: [Float] (256-dim, session moving average)
  └─ lastUsed: Date

SpeakerProfileStore (persistence layer)
  ├─ save / load / delete profiles
  └─ Storage: ~/QuickTranscriber/speakers/ (JSON files)
```

**Workflow:**
1. **Auto-create profiles:** On session end, propose saving all speaker profiles as unnamed ("Speaker A", "Speaker B", ...)
2. **Name assignment:** Settings > Speakers — list all profiles, edit names
3. **Session start (optional):** "Select participants" UI before recording. Initialize `EmbeddingBasedSpeakerTracker` with selected speaker embeddings
4. **Unknown speakers:** Speakers not matching any profile are auto-added (respects Phase 1 `expectedSpeakerCount` limit)

**Integration with Phase 1:**
- Selecting 3 participants → auto-sets `expectedSpeakerCount=3`
- Pre-loaded embeddings eliminate the "warm-up period" (first few chunks have no profile to match against)

**Out of Scope (YAGNI):**
- Voice enrollment recording UI ("please speak into the mic")
- Multi-device profile sync

### Phase 3: User Feedback (Active Learning)

**Goal:** Improve accuracy over sessions through user corrections. Meetings get more accurate over time.

**Core Insight:** Current system updates profiles with all chunk embeddings, including misidentified ones. This pollutes profiles. Solution: update only with confirmed embeddings.

**Architecture Change:**
```
During session:
  chunk → identifySpeaker → assign label (tentative, for display)
  ※ Do NOT update profile immediately

After session (or in real-time):
  User confirms/corrects speaker labels
  → Confirmed segment embeddings update correct speaker profile
  → Corrected segments reassign embedding to correct profile
  → Bad-marked segments excluded from profile updates
```

**UI:**
1. Tap speaker label (A:, B:) in transcript → select correct speaker from enrolled list
2. Uncorrected labels treated as "implicit confirmation" (configurable on/off)
3. Explicitly "bad"-marked segments excluded from profile updates

**Cross-Session Improvement Cycle:**
```
Meeting 1: Initial profile construction (lower accuracy)
  → User corrects a few segments
  → Save profiles updated with confirmed embeddings only

Meeting 2: Start with improved profiles (better accuracy)
  → Fewer corrections needed
  → Further refined profiles saved

Meeting N: Profiles converge, corrections rarely needed
```

**Why This Stays Simple:**
- Embedding representation unchanged (256-dim single vector)
- Update logic reuses existing moving average
- Only change: filter WHICH embeddings are used for updates (confirmed only)
- No probability distributions, no complex models

### Phase C: Algorithm Improvements (Parallel, Data-Driven)

Specific techniques chosen based on Phase 0 AMI benchmark results.

**Candidate 1: Confidence Score Propagation (high priority)**
- Expose cosine similarity as confidence score through the pipeline
- Highlight low-confidence segments in UI (guides Phase 3 feedback)
- Cost: small (value already computed, just needs propagation)
- Synergy: directly enhances Phase 3 feedback efficiency

**Candidate 2: Viterbi Path Smoothing**
- Apply transition costs (penalize speaker changes) to label sequence
- More principled replacement for SpeakerLabelTracker's confirmationThreshold=2
- Effect: further reduce label flips
- Cost: medium (transition probability design needed)
- Decision: after Phase 0 results

**Candidate 3: Weighted Embedding Updates**
- Dynamically adjust alpha based on confidence (high confidence → larger weight)
- Effect: reduce impact of noisy chunks on profiles
- Cost: small
- Decision: after Phase 0 results

## Implementation Priority

```
Phase 0 (AMI validation)     ──→ Informs Phase C decisions
  ↓
Default chunkDuration=5s     ──→ Immediate improvement
  ↓
Phase 1 (speaker count)      ──→ Small cost, large effect
  ↓
Phase 2 (enrollment)         ──→ Cross-session memory
  ↓                               ↕ (tightly coupled)
Phase 3 (feedback)           ──→ Progressive improvement
  ↕
Phase C (confidence score)   ──→ Parallel with Phase 2-3
Phase C (Viterbi, weighted)  ──→ After Phase 0 data analysis
```

## Benchmark Datasets

| Dataset | Domain | Speakers | Duration | Source |
|---------|--------|----------|----------|--------|
| CALLHOME EN | Phone calls | 2 | ~50 conversations | HuggingFace talkbank/callhome |
| CALLHOME JA | Phone calls | 2 | ~50 conversations | HuggingFace talkbank/callhome |
| AMI Meeting | Meetings | 3-5 | 171 hours | HuggingFace edinburghcstr/ami |
