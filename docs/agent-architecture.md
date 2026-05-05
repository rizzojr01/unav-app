# UNav Agent Architecture

## Goal

Introduce a professional, maintainable agent layer for UNav that:

- supports blind and low-vision users with natural language interaction
- can call existing backend functions safely
- personalizes behavior per `user_id`
- evolves through user feedback and session history
- preserves deterministic navigation correctness

This document proposes where the agent should live, which modules it should own, and the exact task/schema boundaries needed to keep future iteration easy.

## Current System Split

Based on the current codebases:

- `~/Desktop/unav`
  - deterministic algorithm core
  - mapping, localization, path planning, command generation
- `~/Desktop/UNav_socket`
  - FastAPI service layer
  - task orchestration
  - user-authenticated `/run_task`
  - per-user session state
- `unav_app`
  - Flutter interaction layer
  - destination selection
  - navigation UI
  - audio, AR, haptics, accessibility

## Architecture Decision

### Keep `unav` Deterministic

`unav` should remain the source of truth for:

- localization
- route computation
- waypoint advancement truth
- floorplan pose
- command generation inputs
- map and POI geometry

Do not let the agent directly decide:

- whether a waypoint was reached
- whether the user is off route
- which pose is correct
- where the path geometry should be

### Add the Agent to `UNav_socket`

`UNav_socket` is the correct home for the agent because it already has:

- authenticated user context
- task dispatching
- a stable API boundary
- per-user in-memory session state
- the ability to call deterministic `unav` tasks

The agent should act as:

- a tool-using orchestration layer
- a personalization layer
- a natural-language interpretation layer

### Keep `unav_app` Thin

The app should not host the main reasoning logic.

The app should:

- capture speech/text input
- display/confirm resolved destinations
- surface agent explanations
- send user feedback
- sync user preference state

## Product Scope for V1

The first agent release should focus on three high-value capabilities:

1. voice destination selection
2. preference adjustment from user feedback
3. navigation state explanation

These are high impact, low risk, and avoid moving safety-critical logic into the model.

## Proposed `UNav_socket` Module Layout

```text
UNav_socket/
  api/
    task_api.py
    user_api.py

  core/
    task_registry.py
    unav_state.py
    tasks/
      general.py
      unav.py
      agent.py
    agent/
      runtime.py
      policy.py
      profile_store.py
      session_context.py
      prompt_builder.py
      response_parser.py
      tool_router.py
      tools/
        destination_tools.py
        navigation_tools.py
        preference_tools.py
        explanation_tools.py

  models/
    schemas.py
    agent_schemas.py
```

## Responsibility by Module

### `core/tasks/agent.py`

Registers externally callable agent tasks for `/run_task`.

This layer should be very thin:

- validate inputs
- load user profile/session context
- delegate to `core/agent/runtime.py`
- return structured results

### `core/agent/runtime.py`

Central orchestrator for the agent.

Responsibilities:

- receives task intent and user input
- gathers profile and current navigation/session context
- decides which tool chain to invoke
- calls the LLM only for interpretation/explanation
- returns structured outputs

### `core/agent/policy.py`

Defines what the agent may and may not do.

This is critical for future maintainability.

Allowed:

- destination interpretation
- candidate ranking
- preference updates
- explanation generation
- verbosity/language/audio-mode tuning

Forbidden:

- pose mutation
- path override
- waypoint truth override
- arbitrary session mutation outside a whitelist

### `core/agent/profile_store.py`

Persistent user profile storage.

V1 can start with SQLite or a JSON-backed DB table in the existing service.
Later it can move to a dedicated datastore without changing task schemas.

### `core/agent/session_context.py`

Builds a safe, structured snapshot from:

- `get_session(user_id)` in `core/unav_state.py`
- recent navigation state
- selected destination
- language/unit settings

This prevents the LLM from reading raw mutable session blobs.

### `core/agent/tool_router.py`

Maps LLM tool calls to internal deterministic service functions.

This layer keeps the model decoupled from backend implementation details.

### `core/agent/tools/*.py`

Grouped by domain so future changes stay isolated.

Suggested split:

- `destination_tools.py`
- `navigation_tools.py`
- `preference_tools.py`
- `explanation_tools.py`

## Proposed External Agent Tasks

Register these in `core/task_registry.py` by adding `AGENT_TASKS`.

### 1. `agent_interpret_destination`

Purpose:

- parse natural language destination requests into a structured query

Example input:

```json
{
  "utterance": "Take me to the nearest restroom",
  "language": "en",
  "user_id": "123"
}
```

Example output:

```json
{
  "intent": "navigate",
  "destination_query": {
    "category": "restroom",
    "name_hint": null,
    "floor_hint": null,
    "preference": "nearest"
  },
  "needs_clarification": false
}
```

### 2. `agent_resolve_destination`

Purpose:

- resolve a structured destination query against deterministic POI/destination data

Example output:

```json
{
  "status": "resolved",
  "candidates": [
    {
      "destination_id": "restroom_1f_east",
      "name": "East Restroom",
      "floor": "1F",
      "distance_hint_m": 18.4
    }
  ],
  "needs_confirmation": true
}
```

### 3. `agent_adjust_preferences`

Purpose:

- parse and apply user preference feedback

Example input:

```json
{
  "utterance": "Please slow the guidance down and keep using Chinese",
  "user_id": "123"
}
```

Example output:

```json
{
  "applied_changes": [
    {
      "key": "guidance_tempo_multiplier",
      "value": 0.8
    },
    {
      "key": "language",
      "value": "zh"
    }
  ],
  "message": "I slowed the guidance down and will continue using Chinese."
}
```

### 4. `agent_explain_navigation_state`

Purpose:

- answer questions like:
  - "What should I do now?"
  - "Why is it beeping?"
  - "How far is the next waypoint?"

Example output:

```json
{
  "message": "Turn slightly left and walk about 5 meters to the next waypoint.",
  "state_summary": {
    "distance_to_waypoint_m": 5.2,
    "heading_error_deg": 14.0,
    "off_route": false
  }
}
```

## Internal Tool Contracts

The runtime should expose deterministic internal tools with narrow signatures.

### Destination Tools

```python
search_destinations(query: DestinationQuery, user_id: str) -> list[DestinationCandidate]
select_destination(destination_id: str, user_id: str) -> dict
get_recent_destinations(user_id: str) -> list[str]
```

### Navigation Tools

```python
get_navigation_state(user_id: str) -> NavigationStateSnapshot
repeat_last_instruction(user_id: str) -> dict
trigger_relocalization(user_id: str) -> dict
```

### Preference Tools

```python
get_user_profile(user_id: str) -> UserProfile
update_user_profile(user_id: str, patch: PreferencePatch) -> UserProfile
record_feedback_event(user_id: str, event: FeedbackEvent) -> None
```

### Explanation Tools

```python
build_navigation_summary(user_id: str) -> NavigationExplanationContext
build_destination_resolution_summary(user_id: str, candidates: list[DestinationCandidate]) -> dict
```

## Data Models

## `models/agent_schemas.py`

Suggested Pydantic models:

```python
from pydantic import BaseModel, Field
from typing import Literal, Optional

class DestinationQuery(BaseModel):
    category: Optional[str] = None
    name_hint: Optional[str] = None
    floor_hint: Optional[str] = None
    building_hint: Optional[str] = None
    preference: Optional[Literal["nearest", "specific", "any"]] = "any"

class DestinationCandidate(BaseModel):
    destination_id: str
    name: str
    category: Optional[str] = None
    floor: Optional[str] = None
    building: Optional[str] = None
    distance_hint_m: Optional[float] = None
    confidence: Optional[float] = None

class UserProfile(BaseModel):
    user_id: str
    language: str = "en"
    unit: str = "meters"
    preferred_audio_mode: str = "auto"
    guidance_tempo_multiplier: float = 1.0
    countdown_enabled: bool = True
    haptic_level: str = "medium"
    verbosity: str = "low"
    favorite_destination_ids: list[str] = Field(default_factory=list)

class PreferencePatch(BaseModel):
    language: Optional[str] = None
    unit: Optional[str] = None
    preferred_audio_mode: Optional[str] = None
    guidance_tempo_multiplier: Optional[float] = None
    countdown_enabled: Optional[bool] = None
    haptic_level: Optional[str] = None
    verbosity: Optional[str] = None

class NavigationStateSnapshot(BaseModel):
    has_active_navigation: bool
    destination_id: Optional[str] = None
    destination_name: Optional[str] = None
    next_waypoint_name: Optional[str] = None
    distance_to_waypoint_m: Optional[float] = None
    heading_error_deg: Optional[float] = None
    off_route: bool = False
```

## User Profile Strategy

### Session vs Profile

Do not overload `core/unav_state.py` session data with long-lived preferences.

Keep two layers:

- session state
  - transient
  - current destination, current floor, current pose, current tracking state
- user profile
  - persistent
  - language, audio preferences, verbosity, favorite destinations

This avoids future maintenance pain.

### Recommended Storage

V1:

- profile table in the service DB, or
- a dedicated JSON/SQLite store behind `profile_store.py`

Later:

- migrate to PostgreSQL or another durable service store

The runtime should only talk to `profile_store.py`, never directly to storage implementation details.

## Prompting Strategy

Use the model only for:

- destination intent extraction
- ambiguity resolution phrasing
- explanation phrasing
- preference interpretation

Do not ask it to generate navigation truth.

Preferred pattern:

- tool-first orchestration
- constrained JSON outputs
- deterministic candidate resolution

### Example Prompt Contract

For destination interpretation, the model should output only JSON:

```json
{
  "category": "restroom",
  "name_hint": null,
  "floor_hint": null,
  "building_hint": null,
  "preference": "nearest"
}
```

No free-form prose should be accepted at the parsing boundary.

## App Integration Plan

The app already has a good integration point in:

- [lib/api/api_service.dart](../lib/api/api_service.dart)

The current destination flow is still list-based in:

- [lib/screens/destination_select_screen.dart](../lib/screens/destination_select_screen.dart)

### Minimal app changes for V1

1. add `ApiService` wrappers for agent tasks
2. add a voice/text destination entry point before the list screen
3. if resolution is unique, continue to the existing `select_destination` flow
4. if resolution is ambiguous, show a clarification dialog or speech prompt

This keeps the current navigation UI intact.

## Migration Plan

### Phase 1

- add `agent_schemas.py`
- add `core/tasks/agent.py`
- add `AGENT_TASKS` to `core/task_registry.py`
- implement destination interpretation and resolution

### Phase 2

- add persistent `profile_store.py`
- implement preference adjustment tasks
- persist per-user defaults

### Phase 3

- add navigation explanation tasks
- expose conversational help in the app

### Phase 4

- add behavior analytics and preference learning
- recommend defaults from repeated user corrections

## Guardrails

### Safe to let the agent change

- language
- verbosity
- countdown enablement
- tempo multiplier within a bounded range
- preferred audio mode
- haptic level

### Must remain deterministic

- localization outputs
- floorplan pose
- path geometry
- waypoint advancement truth
- off-route truth
- destination coordinates

## Why This Design Ages Well

This split is optimized for future modification difficulty:

- `unav` remains stable and reusable
- `UNav_socket` gains the orchestration complexity
- `unav_app` stays thin and platform-friendly
- user-specific logic is isolated from deterministic navigation
- storage implementation can evolve without changing public task schemas
- future Android, web, or multimodal clients can reuse the same agent service

## Recommended Next Step

Implement only one real agent workflow first:

- voice destination selection

This is the cleanest first milestone because it:

- directly helps blind users
- uses existing destination/task infrastructure
- does not touch safety-critical navigation truth
- creates the foundation for later personalization
