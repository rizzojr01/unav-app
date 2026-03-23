# UNav Agent Task Contracts

This document defines the first concrete task contracts between `unav_app` and
`UNav_socket` for the agent layer.

These contracts are designed to:

- keep the app thin
- keep `unav` deterministic
- allow `UNav_socket` to host the LLM/tool orchestration
- make future task evolution backwards-compatible

## Design Principles

- All agent requests go through the existing `/api/run_task` endpoint.
- Every task remains authenticated and receives `user_id` server-side.
- Agent tasks should return structured JSON, not free-form text blobs only.
- Destination resolution remains deterministic after intent interpretation.
- The model may interpret, rank, clarify, and explain, but not override route truth.

## Initial Task Set

## 1. `agent_interpret_destination`

Converts natural language into a structured destination query.

### Request

```json
{
  "task": "agent_interpret_destination",
  "inputs": {
    "utterance": "Take me to the nearest restroom",
    "language": "en",
    "current_place": "langone",
    "current_building": "main",
    "current_floor": "1F"
  }
}
```

### Response

```json
{
  "intent": "navigate",
  "destination_query": {
    "category": "restroom",
    "name_hint": null,
    "building_hint": null,
    "floor_hint": null,
    "preference": "nearest"
  },
  "needs_clarification": false,
  "message": "Looking for the nearest restroom."
}
```

## 2. `agent_resolve_destination`

Resolves a structured query to one or more deterministic destination candidates.

### Request

```json
{
  "task": "agent_resolve_destination",
  "inputs": {
    "destination_query": {
      "category": "restroom",
      "name_hint": null,
      "building_hint": null,
      "floor_hint": null,
      "preference": "nearest"
    }
  }
}
```

### Response

```json
{
  "status": "resolved",
  "needs_confirmation": true,
  "candidates": [
    {
      "destination_id": "restroom_1f_east",
      "name": "East Restroom",
      "category": "restroom",
      "building": "Main Building",
      "floor": "1F",
      "distance_hint_m": 18.4,
      "confidence": 0.96
    }
  ],
  "message": "I found the nearest restroom."
}
```

### Ambiguous Response

```json
{
  "status": "ambiguous",
  "needs_confirmation": true,
  "candidates": [
    {
      "destination_id": "elevator_west_1f",
      "name": "West Elevator",
      "category": "elevator",
      "building": "Main Building",
      "floor": "1F",
      "distance_hint_m": 12.1,
      "confidence": 0.83
    },
    {
      "destination_id": "elevator_east_1f",
      "name": "East Elevator",
      "category": "elevator",
      "building": "Main Building",
      "floor": "1F",
      "distance_hint_m": 16.7,
      "confidence": 0.79
    }
  ],
  "message": "I found two elevators. Do you want the west elevator or the east elevator?"
}
```

## 3. `agent_adjust_preferences`

Interprets user feedback and applies a bounded profile patch.

### Request

```json
{
  "task": "agent_adjust_preferences",
  "inputs": {
    "utterance": "Please slow the guidance down and keep using Chinese"
  }
}
```

### Response

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

## 4. `agent_explain_navigation_state`

Produces a human-friendly explanation using structured navigation truth.

### Request

```json
{
  "task": "agent_explain_navigation_state",
  "inputs": {
    "question": "What should I do now?"
  }
}
```

### Response

```json
{
  "message": "Turn slightly left and walk about 5 meters to the next waypoint.",
  "state_summary": {
    "distance_to_waypoint_m": 5.2,
    "heading_error_deg": 14.0,
    "off_route": false,
    "next_waypoint_name": "Waypoint 3"
  }
}
```

## App-Side Integration Order

Recommended implementation order in `unav_app`:

1. `agent_interpret_destination`
2. `agent_resolve_destination`
3. `agent_adjust_preferences`
4. `agent_explain_navigation_state`

The app should keep the current list-based destination flow as a fallback while
the new voice/text entry path is introduced.

## Compatibility Notes

- New fields should be additive.
- Clients should ignore unknown keys.
- Server should tolerate omitted optional hints.
- Final destination selection should still call the existing `select_destination` task.
