# JiraKit — Design Doc

Nov 19, 2026 · @Ori Dahari

## Overview

JiraKit lets one Python codebase declare the issue types of a single Jira Service Management (JSM) project as typed classes, validate them, preview them to users, and send them to Jira. The project is fixed, so there is no multi-project or multi-tracker support.

**Goals**

- Declare a field once (ID, type, required, label, allowed values, conversions) and reuse it for payloads, previews and validation.
- Catch bad values at construction time, offline, and report every problem together.
- Detect drift between the code and the live Jira configuration on demand.
- Keep the core free of I/O, so most behavior is testable without Jira.

**Non-goals**

- Multiple projects, other trackers, or a general Jira ORM.
- Runtime checks of arbitrary Python types beyond enums, literals, lists and optionals.
- Calling Jira from constructors.

**Naming rule:** anything that knows about Jira or this project carries the `Jira` prefix (`JiraFieldId`, `JiraField`, `JiraModel`, `JiraFieldSpec`, `JiraIssueSchema`, `JiraMeta`, `JiraMetaProvider`, `JiraClient`). Generic machinery keeps neutral names (`FieldCodec`, `CodecResolver`, `SchemaSource`, `Problem`). The prefix is a placeholder: a script (`rename-prefix.sh <ProjectName>`) replaces it with the real project's name at the end, so that name never appears in these docs or in the generated code.

## Architecture

The class you write is only one way to declare a schema. It is compiled once into plain, immutable data (`JiraIssueSchema`), and every other part works on that data plus a dict of values, never on the class. Changing how issue types are declared later (pydantic, YAML, generated from Jira metadata) replaces one component and leaves the rest alone.

```text
 declaration: class Bug(JiraModel) ...
        |  SchemaSource.schema_for(cls)
        v
 JiraIssueSchema  (frozen data)  <--  CodecResolver picks one FieldCodec per field
        |
        +-- validate(schema, values)                 -> list[Problem]
        +-- to_payload / to_create_payload           -> Jira API dict
        +-- from_payload(schema, payload)            -> values dict
        +-- to_preview(schema, values)               -> list[PreviewRow]
        +-- check_remote(schema, values, JiraMeta)   -> list[Problem]
        +-- JiraClient.create / update               -> HTTP   (the only I/O, with JiraMetaProvider)
```

**Rules**

- Values are a `dict[str, Any]` keyed by attribute name. A field is unset when it is absent from the dict or `None`.
- The core (schema, codecs, validate, payload, preview, remote check) does no I/O and never imports the class frontend (`model.py`, `source.py`).
- `JiraModel` is a thin facade: each method calls one function from the core.

## Core data types

```python
class JiraFieldId(StrEnum):           # already exists; gains a default label
    label: str
    def __new__(cls, value: str, label: str): ...
    SUMMARY = ("summary", "Summary")
    SEVERITY = ("customfield_10042", "Severity")

@dataclass(frozen=True)
class JiraFieldSpec:
    attr: str                # python attribute name
    id: JiraFieldId
    type: Any                # resolved annotation, e.g. Severity or list[Component] | None
    required: bool
    label: str               # JiraField.label, else JiraFieldId.label
    codec: FieldCodec

@dataclass(frozen=True)
class JiraIssueSchema:
    issue_type: str                          # e.g. "Bug" (the JSM request/issue type)
    fields: Mapping[str, JiraFieldSpec]      # by attribute name, in declaration order

@dataclass(frozen=True)
class Problem:
    field: str | None        # attribute name; None for model-level problems
    code: str                # missing_required, invalid_choice, invalid_value, unknown_field, duplicate_id,
                             # unavailable_remote, required_remote, not_allowed_remote
    message: str

class JiraError(Exception):  # carries every problem at once
    problems: tuple[Problem, ...]
```

`JiraField` (the marker used in declarations) is covered under Declaration frontend. Errors are data: functions return `list[Problem]`, and only the facade raises `JiraError`.

## Interfaces

Five `typing.Protocol`s sit at the seams where change is likely. Each has one small implementation now.

```python
JSON = None | bool | int | float | str | list["JSON"] | dict[str, "JSON"]

class FieldCodec(Protocol):        # everything about ONE field's values
    def validate(self, value: Any) -> Any: ...   # coerce, or raise ValueError (InvalidChoice for a bad option)
    def encode(self, value: Any) -> JSON: ...    # python value -> Jira API value
    def decode(self, raw: JSON) -> Any: ...      # Jira API value -> python value
    def display(self, value: Any) -> str: ...    # python value -> text for people

class CodecResolver(Protocol):     # which codec a type gets
    def resolve(self, tp: Any, override: FieldCodec | None = None) -> FieldCodec: ...

class SchemaSource(Protocol):      # where schemas come from
    def schema_for(self, model: type) -> JiraIssueSchema: ...

class JiraMetaProvider(Protocol):  # remote truth about the project, cached
    def meta(self, issue_type: str) -> JiraMeta: ...

class JiraClient(Protocol):        # transport only
    def create(self, payload: dict) -> IssueRef: ...
    def update(self, key: str, payload: dict) -> None: ...
```

One codec owns all four jobs for a field. Payload and preview are therefore produced from the same value by the same object and cannot drift apart. `SchemaSource` has one implementation today (`AnnotatedSource`); a pydantic-based or Jira-generated source can be added without touching consumers.

## Declaration frontend

Issue types are classes. Each attribute is declared with `Annotated[<type>, JiraField(...)]`. The annotation stays the real type; `JiraField` rides along as metadata, the same way pydantic reads `Annotated[int, Field(gt=0)]`.

```python
@dataclass(frozen=True)
class JiraField:
    id: JiraFieldId
    required: bool = False
    label: str | None = None      # overrides JiraFieldId.label in previews
    codec: FieldCodec | None = None   # overrides the codec chosen from the type

class Bug(JiraModel):
    issue_type: ClassVar[str] = "Bug"
    title: Annotated[str, JiraField(JiraFieldId.SUMMARY, required=True, label="Title")]
    severity: Annotated[Severity, JiraField(JiraFieldId.SEVERITY, codec=option(Severity))]
    components: Annotated[list[Component], JiraField(JiraFieldId.COMPONENTS, codec=list_of(named(Component)))]
```

**How a class becomes a schema:** `JiraModel.__init_subclass__` calls `AnnotatedSource.schema_for(cls)`. It reads `get_type_hints(cls, include_extras=True)`, takes the first `JiraField` in each `Annotated` hint, asks the `CodecResolver` for a codec, and builds a `JiraIssueSchema`. Annotations without a `JiraField` and `ClassVar`s are ignored; base-class fields are inherited. A class with no `issue_type` in its MRO is treated as abstract and is not compiled.

**`JiraModel` facade methods** (each delegates to a core function): `schema()`, `values()`, `to_payload()`, `to_create_payload(project_key)`, `from_payload(payload)`, `to_preview()`, `validate_against(meta)`, `submit(client, project_key)`.

**Why `Annotated` and not `title: str = jira_field(...)`:** the default slot stays free for real defaults, and the same declarations keep working if the models later move to pydantic.

## Codecs and type resolution

A `FieldCodec` is chosen for each field from its type, unless `JiraField(codec=...)` overrides it. Structural codecs follow the type; Jira-shape codecs (`option`, `named`, `user`, ADF text) are never chosen automatically, because the type alone does not say which JSON shape Jira expects.

| Codec | Handles | Encoded for Jira | Display text |
| --- | --- | --- | --- |
| `PassthroughCodec` | str, int, float, bool | the value | `str(value)` |
| `EnumCodec(E)` | an `Enum` subclass `E` | `member.value` | `str(member.value)` |
| `LiteralCodec(values)` | `Literal[...]` | the value | `str(value)` |
| `OptionalCodec(inner)` | `X \| None` | never called for `None` | empty string for `None` |
| `ListCodec(inner)` | `list[X]` | list of `inner.encode` | items joined with ", " |
| `OptionCodec(inner)` | select / multi-select fields | `{"value": inner.encode(v)}` | `inner.display` |
| `NamedCodec(inner)` | priority, components | `{"name": inner.encode(v)}` | `inner.display` |
| `UserCodec` | user fields (account ID string) | `{"accountId": v}` | the ID |
| `DatetimeCodec` | timezone-aware `datetime` | `YYYY-MM-DDTHH:MM:SS.000+hhmm` | `YYYY-MM-DD HH:MM` |
| `AdfTextCodec` | text on API v3 | ADF document | the text |

**Resolution order** (`DefaultCodecResolver.resolve(tp, override)`): override, then `X | None`, `list[X]`, `Literal`, `Enum`, `datetime`, and otherwise `PassthroughCodec`. Helpers keep declarations short: `option(tp)`, `named(tp)`, `user()`, `list_of(codec)`. `FnCodec(base, encode=..., decode=..., display=...)` overrides single hooks of another codec.

A bad option raises `InvalidChoice` (a `ValueError`) whose message lists the allowed values. `decode(encode(x)) == x` must hold for every codec.

## Validation and errors

Validation returns data and never raises. Only the `JiraModel` facade turns problems into a `JiraError`, which carries all of them at once.

```python
def coerce(schema, values) -> tuple[dict[str, Any], list[Problem]]   # validated, coerced values + problems
def validate(schema, values) -> list[Problem]                        # coerce(...)[1]
```

**Checks, in this order**

1. Unknown attribute name: `unknown_field`.
2. Required field absent or `None`: `missing_required`.
3. `codec.validate(value)` raises `InvalidChoice`: `invalid_choice` (message lists allowed values).
4. `codec.validate(value)` raises any other `ValueError`: `invalid_value`.

Problems come back in schema declaration order, with unknown fields last. `JiraModel.__init__` coerces all values and raises one `JiraError`; `__setattr__` coerces the one field being set, so later assignment cannot bypass the check.

**Two layers.** Static validation (above) is always on, fast and offline. Remote validation compares values with Jira's live configuration (see Remote metadata) and runs only when asked. Both produce the same `Problem` type, so callers handle them the same way.

## Payloads and preview

**Payloads.** `to_payload(schema, values)` returns `{"fields": {<JiraFieldId>: <encoded>}}` for set fields only. `to_create_payload(schema, values, project_key)` adds `project` and `issuetype`. Updates use `to_payload` alone, because an update must not carry `project` or `issuetype`. `from_payload(schema, payload)` is the inverse: it decodes known field IDs, ignores unknown ones, and returns a values dict that the model constructor then validates. `JiraFieldId` members are strings, so `json.dumps` works without conversion.

**Open decision (JSM):** a customer request in Jira Service Management has a request type. The supported route for that is the Service Desk API (`POST /rest/servicedeskapi/request` with `serviceDeskId`, `requestTypeId` and `requestFieldValues`), while `POST /rest/api/2/issue` with `project` and `issuetype` creates a plain issue. Which one fits this project depends on your instance and has not been verified here. The field encoding is the same either way; only the envelope differs, and it is confined to `to_create_payload` and `JiraClient.create`. API v2 versus v3 (plain-text versus ADF descriptions) is likewise confined to the codec choice.

**Preview.** `to_preview(schema, values, include_missing_required=True)` returns `list[PreviewRow]` in declaration order, where `PreviewRow = (label, text, required, missing)`. A set field shows `codec.display(value)`; a required field that is unset shows an empty text with `missing=True`. The function returns rows, not a formatted string, so a CLI, a Slack message and a web page can each render them their own way.

## Remote metadata and drift checks

Option lists and required flags are configured in Jira per project and issue type, and admins can change them. Enums in code are fast and offline but can go stale, so a second, opt-in layer compares values with Jira's live configuration.

```python
@dataclass(frozen=True)
class JiraFieldMeta:
    id: str
    required: bool
    allowed_values: frozenset[str] | None     # None when the field has no fixed option list

@dataclass(frozen=True)
class JiraMeta:
    issue_type: str
    fields: Mapping[str, JiraFieldMeta]

def parse_createmeta(raw: Mapping[str, Any], issue_type: str) -> JiraMeta
def check_remote(schema, values, meta: JiraMeta) -> list[Problem]
```

**`check_remote` rules**

- A schema field whose ID is absent from the metadata: `unavailable_remote`.
- A field Jira marks required that has no value (including fields the schema does not declare): `required_remote`.
- A value whose encoded form is not in `allowed_values`: `not_allowed_remote`. Comparison uses the `value` or `name` key of the encoded option, else its string form.

**Where metadata comes from:** a `JiraMetaProvider`. The HTTP one reads Jira's create-metadata endpoint for the project and issue type (the exact path and response shape differ between Jira versions, so `parse_createmeta` must accept the shape your instance returns; verify against a real response). A `CachedMetaProvider` wraps any provider with a TTL.

**When to run it:** explicitly, never from a constructor. Typical uses are before `submit`, in CI against a recorded metadata fixture (a contract test that fails when code enums drift), and on a schedule against the live instance.

## Testing, extension points and decisions

**Tests that guard the seams**

- Round trip for every codec: `decode(encode(x)) == x`.
- Contract test: a recorded create-metadata fixture is parsed and checked against the example models, offline. It fails when an enum in code drifts from Jira.
- Architecture test: core modules must not import `model.py` or `source.py`.
- README test: the code blocks in the README are executed, so the docs cannot rot.

**Extension points**

- New field type: add a codec and teach `DefaultCodecResolver` about it.
- Different declaration style (pydantic, YAML, generated from Jira): add a `SchemaSource`.
- Other API version, endpoint or auth: add a `JiraClient` or `JiraMetaProvider`, and adjust `to_create_payload`.
- New consumer (Slack message, web form): read `PreviewRow`s.

**Decisions**

- `Annotated` declarations instead of default-value markers, to keep the default slot free and stay pydantic-compatible.
- Errors are data (`Problem`); only the facade raises.
- A field is unset when absent or `None`, and unset fields are never sent.
- One codec per field owns validation, encoding, decoding and display.
- Remote validation is opt-in and never runs from a constructor.
- The core does no I/O.

**Open questions (answer before W5 and W8 are finalized)**

1. Create through the platform API or the Service Desk API (request types)?
2. API v2 (plain-text description) or v3 (ADF)?
3. Jira Cloud or Data Center? This sets auth and the create-metadata path.
4. Which HTTP library does the repo already use?
5. Assumed: one `JiraModel` subclass per request or issue type, with `issue_type` set to its Jira name. Confirm.
