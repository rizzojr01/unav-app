# UNav Socket Agent Implementation Plan

This document translates the high-level agent architecture into concrete,
file-by-file changes for `~/Desktop/UNav_socket`.

It is based on the current backend structure:

- `api/task_api.py`
- `core/task_registry.py`
- `core/unav_state.py`
- `core/tasks/general.py`
- `core/tasks/unav.py`
- `models/schemas.py`

## What the Existing Backend Already Gives Us

### 1. Unified Authenticated Task Entry

`api/task_api.py` already:

- authenticates every request
- injects `user_id` into inputs
- supports both JSON and multipart
- looks up callable tasks through `get_task(task_name)`

This means the agent should be implemented as more tasks, not as a parallel API stack.

### 2. Simple Task Registry

`core/task_registry.py` currently merges:

- `GENERAL_TASKS`
- `UNAV_TASKS`

This is a clean insertion point for:

- `AGENT_TASKS`

### 3. Existing Per-User Session State

`core/unav_state.py` already has:

- `get_session(user_id)`
- an in-memory session cache
- current place/building/floor
- selected destination
- unit/language-like state

This is good for request-scoped context, but not enough for long-lived personalization.

## Implementation Strategy

## Step 1: Add Agent-Specific Schemas

### New file

`models/agent_schemas.py`

Purpose:

- provide strong structure for agent task inputs/outputs
- keep future frontend and backend changes compatible

Recommended models:

- `DestinationQuery`
- `DestinationCandidate`
- `UserProfile`
- `PreferencePatch`
- `NavigationStateSnapshot`
- `AgentInterpretDestinationResponse`
- `AgentResolveDestinationResponse`
- `AgentAdjustPreferencesResponse`
- `AgentExplainNavigationStateResponse`

## Step 2: Add a Persistent Profile Store

### New file

`core/agent/profile_store.py`

V1 responsibilities:

- `get_user_profile(user_id)`
- `upsert_user_profile(user_id, patch)`
- `record_feedback(user_id, event)`

Implementation recommendation:

- start with SQLite if you want persistence quickly
- or use the existing DB layer if you already have a clean place for profile rows

Important:

- do not store long-lived preference data only in `core/unav_state.py`
- session state and user profile should be separate

## Step 3: Add Session Context Builder

### New file

`core/agent/session_context.py`

Responsibilities:

- read `get_session(user_id)`
- normalize it into a typed structure
- expose only safe fields to the agent runtime

Suggested output:

```python
{
    "current_place": "...",
    "current_building": "...",
    "current_floor": "...",
    "selected_dest_id": 12,
    "target_place": "...",
    "target_building": "...",
    "target_floor": "...",
    "language": "en",
    "unit": "meters"
}
```

This prevents the runtime from directly mutating raw session blobs.

## Step 4: Add Tool Layer

### New folder

```text
core/agent/tools/
  destination_tools.py
  navigation_tools.py
  preference_tools.py
  explanation_tools.py
```

### `destination_tools.py`

Should wrap deterministic destination lookup, not LLM reasoning.

Suggested functions:

- `fetch_destinations_for_context(user_id)`
- `resolve_query_against_destinations(destination_query, user_id)`
- `select_destination_for_user(destination_id, user_id)`

It should reuse existing deterministic logic from `core/tasks/unav.py` where possible.

### `preference_tools.py`

Suggested functions:

- `get_profile(user_id)`
- `update_profile(user_id, patch)`

### `navigation_tools.py`

Suggested functions:

- `build_navigation_state_snapshot(user_id)`
- `repeat_last_instruction(user_id)`
- `is_navigation_active(user_id)`

### `explanation_tools.py`

Suggested functions:

- `build_explanation_context(user_id)`
- `format_candidate_summary(candidates)`

## Step 5: Add Runtime and Policy

### New files

- `core/agent/runtime.py`
- `core/agent/policy.py`
- `core/agent/tool_router.py`

### `runtime.py`

Responsibilities:

- receive normalized request
- gather profile + session context
- call the provider
- validate provider output
- call deterministic tools
- return structured response

### `policy.py`

Responsibilities:

- define allowed preference keys
- bound numeric changes
- prevent agent from mutating navigation truth

Example bounds:

- `guidance_tempo_multiplier`: `0.6` to `1.4`
- `verbosity`: `low | medium | high`
- `preferred_audio_mode`: `auto | stereo | spatial`

### `tool_router.py`

Keeps provider-facing tool names stable even if backend internals change later.

## Step 6: Add Provider Abstraction

### New files

```text
core/agent/providers/
  base.py
  openai_provider.py
  gemini_provider.py
  factory.py
```

### `base.py`

Suggested interface:

```python
class AgentProvider:
    def interpret_destination(self, *, utterance, language, context): ...
    def adjust_preferences(self, *, utterance, profile, context): ...
    def explain_navigation_state(self, *, question, context): ...
```

### Why this matters

This makes future model swaps cheap.

You can:

- start with OpenAI
- keep Gemini as fallback
- later add local inference

without rewriting task logic.

## Step 7: Add Task Entry Points

### New file

`core/tasks/agent.py`

This should look similar in style to the existing `general.py` and `unav.py`.

Suggested exported tasks:

```python
AGENT_TASKS = {
    "agent_interpret_destination": agent_interpret_destination,
    "agent_resolve_destination": agent_resolve_destination,
    "agent_adjust_preferences": agent_adjust_preferences,
    "agent_explain_navigation_state": agent_explain_navigation_state,
}
```

### Task behavior

#### `agent_interpret_destination(inputs)`

- validate `utterance`
- load language and context
- call provider
- return structured destination query

#### `agent_resolve_destination(inputs)`

- validate `destination_query`
- call deterministic destination resolver
- return candidates and clarification message

#### `agent_adjust_preferences(inputs)`

- call provider for patch interpretation
- run patch through policy validation
- persist to profile store
- return applied changes

#### `agent_explain_navigation_state(inputs)`

- build deterministic snapshot
- call provider for wording only
- return explanation plus raw state summary

## Step 8: Register Agent Tasks

### Modify

`core/task_registry.py`

From:

```python
from core.tasks.general import GENERAL_TASKS
from core.tasks.unav import UNAV_TASKS
```

To:

```python
from core.tasks.general import GENERAL_TASKS
from core.tasks.unav import UNAV_TASKS
from core.tasks.agent import AGENT_TASKS
```

And:

```python
TASKS.update(AGENT_TASKS)
```

This keeps the backend shape consistent with the rest of the service.

## Step 9: Keep `unav` Untouched at First

Do not push agent logic into `~/Desktop/unav` in V1.

If `UNav_socket` needs better deterministic helpers later, add narrow helper methods or wrappers, but keep the algorithm package as:

- geometry truth
- localization truth
- path planning truth

## Recommended Delivery Order

### Milestone A

- `agent_schemas.py`
- `profile_store.py`
- `session_context.py`
- `agent.py`
- `AGENT_TASKS` registration

### Milestone B

- `openai_provider.py`
- `factory.py`
- `agent_interpret_destination`
- `agent_resolve_destination`

### Milestone C

- `agent_adjust_preferences`
- persistent profile writes

### Milestone D

- `agent_explain_navigation_state`
- app-side conversational help

## What Not to Over-Engineer Yet

Do not start with:

- a fully autonomous multi-step agent planner
- unrestricted tool calling
- learned preference optimization
- path override reasoning
- real-time LLM use inside every tracking update

That would increase complexity without helping the first user-facing value.

## Best First Demo

The most professional first demo is:

- user says destination naturally
- backend interprets it
- backend resolves it deterministically
- app confirms the result
- user starts navigation

This will feel intelligent immediately, while still preserving safety and maintainability.
