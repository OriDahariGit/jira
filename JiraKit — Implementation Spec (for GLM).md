# JiraKit — Implementation Spec (for GLM)

Nov 19, 2026 · @Ori Dahari

## How to use this spec

Give the implementing agent (GLM) one workload per session, in order. A workload is done only when its tests pass and the Definition of done checks succeed for the files it touched.

For each session, paste three things: the Global conventions section, the sections of the Design Doc named on the workload's **Read** line, and the workload itself.

**Rules for the implementing agent**

- Implement only the workload you were given. Do not start later ones.
- Keep public names and signatures exactly as written. Private helpers are free.
- Touch only the files listed under **Files**. If another file needs a change, say so under Notes in your final report.
- Add no new dependencies, except where a workload says so.
- If the spec is ambiguous or contradicts the existing code, pick the simplest reading, state it in your report, and keep going.
- Finish by running the tests, linter and type checker, and report what passed and failed.

If a workload proves too big for the model, split it at the point its Notes suggest.

## Global conventions and layout

**Conventions**

- Python 3.11+, standard library only (except W8, which may use the HTTP library the repo already depends on).
- Fully type-annotated; no `Any` unless unavoidable. `from __future__ import annotations` is allowed.
- Frozen dataclasses for data; `typing.Protocol` for interfaces. No metaclasses.
- Core modules do no I/O and never import `model.py` or `source.py`.
- Naming: the `Jira` prefix for anything tied to Jira or this project; neutral names for generic machinery (`FieldCodec`, `CodecResolver`, `SchemaSource`, `Problem`). The only Jira-prefixed names allowed are `JiraFieldId`, `JiraField`, `JiraFieldSpec`, `JiraFieldMeta`, `JiraModel`, `JiraIssueSchema`, `JiraMeta`, `JiraMetaProvider`, `JiraClient`, `HttpJiraClient`, `HttpJiraMetaProvider`, `JiraError`, `JiraApiError`, and the package `jirakit`. A script later renames them to the real project's prefix, so never hard-code a real project name and never invent another Jira-prefixed class name.
- A field is unset when absent or `None`. `None` is never sent to Jira.
- Validation returns `list[Problem]`; only `JiraModel` raises `JiraError`.
- Tests: pytest, one `tests/test_<module>.py` per module, no network.
- Match the repo's existing style, linter and type checker. Find them first.

**Layout** (adapt the package path to where `JiraFieldId` already lives)

```text
jirakit/
  __init__.py     public re-exports            (W9)
  errors.py       Problem, JiraError           (W0)
  fields.py       JiraFieldId (existing), JiraField    (W1)
  schema.py       JiraFieldSpec, JiraIssueSchema       (W1)
  codecs.py       FieldCodec, codecs, resolver         (W2)
  source.py       SchemaSource, AnnotatedSource        (W3)
  model.py        JiraModel facade                     (W3, extended by W4-W9)
  validate.py     coerce, validate                     (W4)
  payload.py      to_payload, from_payload             (W5)
  preview.py      PreviewRow, to_preview               (W6)
  remote.py       JiraMeta, check_remote               (W7)
  client.py       JiraClient, HttpJiraClient           (W8)
tests/
  fixtures/createmeta.json
  test_<module>.py
```

## Order of workloads

Run them in this order. W4, W5 and W6 are independent of each other once W3 is done, so they may run in parallel; everything else is sequential.

```text
W0 scaffold -> W1 core types -> W2 codecs -> W3 declaration
                                               |-> W4 validation --+
                                               |-> W5 payload -----+-> W7 remote check -> W8 client -> W9 docs
                                               '-> W6 preview -----'
```

`model.py` is edited by W3 (created) and then by W4 to W8, each adding only the methods named in its workload. If you run W4 to W6 in parallel, merge `model.py` by hand.

## W0 — Scaffold and error types

**Read:** Design Doc, Core data types. **Depends on:** nothing.

**Goal:** create the package skeleton and the shared error types, and learn the repo's conventions.

**Do first:** find where `JiraFieldId` already lives and which linter, type checker and test runner the repo uses. Put the new package next to it and report the paths.

**Files:** `errors.py`, `__init__.py` (empty for now), `tests/test_errors.py`.

```python
@dataclass(frozen=True)
class Problem:
    field: str | None
    code: str
    message: str

PROBLEM_CODES: Final[frozenset[str]]   # the eight codes listed in the Design Doc

class JiraError(Exception):
    problems: tuple[Problem, ...]
    def __init__(self, problems: Sequence[Problem]) -> None: ...
    # str(error): one line per problem, "<field>: <message>", or just "<message>" when field is None
```

**Rules**

- `JiraError` needs at least one problem (`ValueError` on an empty sequence).
- `Problem.__post_init__` raises `ValueError` if `code` is not in `PROBLEM_CODES`.

**Tests:** str formatting with and without a field; empty list rejected; unknown code rejected; `Problem` is immutable.

**Out of scope:** everything else.

## W1 — Core data types

**Read:** Design Doc, Core data types and Declaration frontend (the `JiraField` part). **Depends on:** W0.

**Goal:** field-ID labels, the `JiraField` marker, and the schema data classes.

**Files:** `fields.py` (edit the existing file), `schema.py`, `tests/test_fields.py`, `tests/test_schema.py`.

```python
# fields.py
class JiraFieldId(StrEnum):
    label: str
    def __new__(cls, value: str, label: str): ...   # every existing member becomes (value, label)

@dataclass(frozen=True)
class JiraField:
    id: JiraFieldId
    required: bool = False
    label: str | None = None
    codec: FieldCodec | None = None     # import FieldCodec only under TYPE_CHECKING
    @property
    def display_label(self) -> str: ...  # self.label or self.id.label

# schema.py
@dataclass(frozen=True)
class JiraFieldSpec:   # attr, id, type, required, label, codec  (see Design Doc)
@dataclass(frozen=True)
class JiraIssueSchema:
    issue_type: str
    fields: Mapping[str, JiraFieldSpec]
    def by_id(self) -> Mapping[JiraFieldId, JiraFieldSpec]: ...
    def required_attrs(self) -> tuple[str, ...]: ...
```

**Rules**

- Existing members: label = the member name with underscores as spaces, title-cased (`SEVERITY` becomes "Severity"), unless the repo already has better labels. Never change a value.
- `JiraFieldId("summary")` still works, `JiraFieldId("nope")` still raises `ValueError`, members still equal their plain strings, and `json.dumps` still serializes them.
- `JiraField.__post_init__` coerces `id` with `JiraFieldId(...)` (use `object.__setattr__`).
- `JiraIssueSchema` stores `fields` in a `MappingProxyType` (read-only, order kept). Two specs with the same `id` raise `JiraError` with a `duplicate_id` problem.

**Tests:** labels on every member; lookup by value; JSON serialization; `display_label` with and without an override; string id coerced; unknown id rejected; `by_id`; `required_attrs`; duplicate-id rejection; schema is read-only.

**Out of scope:** codecs; compiling classes.

## W2 — Codecs and resolver

**Read:** Design Doc, Interfaces and Codecs and type resolution. **Depends on:** W1.

**Goal:** the `FieldCodec` protocol, the built-in codecs, and the default resolver.

**Files:** `codecs.py`, `tests/test_codecs.py`.

```python
class InvalidChoice(ValueError): ...          # message names the bad value and lists the allowed ones
class FieldCodec(Protocol): ...               # validate, encode, decode, display (see Design Doc)

class PassthroughCodec: ...
class EnumCodec:      def __init__(self, enum_type: type[Enum]) -> None: ...
class LiteralCodec:   def __init__(self, values: Sequence[Any]) -> None: ...
class OptionalCodec:  def __init__(self, inner: FieldCodec) -> None: ...
class ListCodec:      def __init__(self, inner: FieldCodec) -> None: ...
class OptionCodec:    def __init__(self, inner: FieldCodec) -> None: ...
class NamedCodec:     def __init__(self, inner: FieldCodec) -> None: ...
class UserCodec: ...
class DatetimeCodec: ...
class AdfTextCodec: ...
class FnCodec:        def __init__(self, base: FieldCodec, *, encode=None, decode=None, display=None) -> None: ...

class DefaultCodecResolver:
    def resolve(self, tp: Any, override: FieldCodec | None = None) -> FieldCodec: ...

def option(tp: Any) -> FieldCodec: ...        # OptionCodec(DefaultCodecResolver().resolve(tp))
def named(tp: Any) -> FieldCodec: ...         # NamedCodec(...)
def user() -> FieldCodec: ...                 # UserCodec()
def list_of(codec: FieldCodec) -> FieldCodec: ...   # ListCodec(codec)
```

**Rules**

- Each codec's wire format and display text are defined by the table in Design Doc, Codecs and type resolution.
- `validate` returns the coerced value. `EnumCodec` accepts a member or its raw value and returns the member; a bad value raises `InvalidChoice`. `LiteralCodec` raises `InvalidChoice` for a value not in the list. `ListCodec` accepts a list or tuple (anything else is `ValueError`) and validates each item. `OptionalCodec` returns `None` for `None`, otherwise delegates.
- `encode` is only called on validated, non-`None` values. `decode(encode(x)) == x` for every validated `x`. Wrapper codecs (`Option`, `Named`, `User`) raise `ValueError` when decoding a payload of the wrong shape.
- `DatetimeCodec`: `validate` accepts an aware `datetime` or an ISO-8601 string and rejects naive datetimes; `encode` uses `%Y-%m-%dT%H:%M:%S.000%z`; `decode` parses that format.
- `AdfTextCodec`: `encode` makes an ADF document with one paragraph per blank-line-separated block and no empty text nodes; `decode` joins paragraph text with a blank line. Only needed for API v3.
- `FnCodec` delegates to `base` for any hook not supplied.
- Resolver: follow the resolution order in the Design Doc. A union with more than one non-`None` member raises `TypeError`. Unsupported generics (`dict`, `set`, `tuple`) fall back to `PassthroughCodec`.

**Tests:** every codec for encode, decode, display and round trip; invalid values for each validating codec; `InvalidChoice` message contents; resolver cases (`Optional[Enum]`, `list[Enum]`, `Literal`, `datetime`, plain `str`, override precedence); partial `FnCodec` override.

**Notes:** if this is too large, split after `FnCodec` and `DefaultCodecResolver` (W2a), and do `OptionCodec`, `NamedCodec`, `UserCodec`, `DatetimeCodec`, `AdfTextCodec` and the four helpers as W2b.

**Out of scope:** reading classes or annotations from models.

## W3 — Declaration frontend and schema compile

**Read:** Design Doc, Declaration frontend and Interfaces. **Depends on:** W2.

**Goal:** compile a class into a `JiraIssueSchema`, and provide a basic `JiraModel` without validation.

**Files:** `source.py`, `model.py`, `tests/test_source.py`, `tests/test_model.py`.

```python
class SchemaSource(Protocol):
    def schema_for(self, model: type) -> JiraIssueSchema: ...

class AnnotatedSource:
    def __init__(self, resolver: CodecResolver | None = None) -> None: ...   # default DefaultCodecResolver()
    def schema_for(self, model: type) -> JiraIssueSchema: ...

class JiraModel:
    issue_type: ClassVar[str]
    def __init_subclass__(cls, **kwargs: Any) -> None: ...   # compiles the schema when issue_type is set
    @classmethod
    def schema(cls) -> JiraIssueSchema: ...
    def __init__(self, **values: Any) -> None: ...
    def values(self) -> dict[str, Any]: ...    # set, non-None values in declaration order
    # __repr__ and __eq__ (same class and equal values())
```

**Rules**

- `schema_for` reads `get_type_hints(model, include_extras=True)`. For each hint whose origin is `Annotated`, take the base type and the first `JiraField` in its metadata. Skip hints without a `JiraField` and skip `ClassVar`s.
- Each field becomes `JiraFieldSpec(attr, id, type=base, required, label=field.display_label, codec=resolver.resolve(base, field.codec))`. Order follows `get_type_hints` (base-class fields first).
- Two attributes with the same `JiraFieldId` raise `JiraError` with a `duplicate_id` problem, at class-definition time.
- A class with no non-empty `issue_type` anywhere in its MRO is abstract: do not compile it, and `schema()` on it raises `TypeError`.
- `__init__` in this workload only rejects unknown keyword arguments (one `JiraError` with an `unknown_field` problem per name) and stores the rest with `setattr`. No coercion yet. An attribute that was never set raises `AttributeError`.

**Tests:** schema from a sample class (ids, required, labels, codecs, order); inheritance; ignored annotations and `ClassVar`; duplicate-id error at definition; abstract base; unknown kwarg lists all names; `values()` skips unset and `None`; equality and repr.

**Out of scope:** validation, payloads, previews.

## W4 — Validation

**Read:** Design Doc, Validation and errors. **Depends on:** W3.

**Goal:** pure validation functions, plus their hooks in `JiraModel`.

**Files:** `validate.py`, `model.py` (edit), `tests/test_validate.py`, `tests/test_model_validation.py`.

```python
def coerce_field(spec: JiraFieldSpec, value: Any) -> tuple[Any, list[Problem]]: ...
def coerce(schema: JiraIssueSchema, values: Mapping[str, Any]) -> tuple[dict[str, Any], list[Problem]]: ...
def validate(schema: JiraIssueSchema, values: Mapping[str, Any]) -> list[Problem]: ...   # coerce(...)[1]
```

**Rules**

- Checks and their order are in the Design Doc. `Problem.field` is the attribute name.
- Messages are readable and use the field's label: `"<label> is required"` for `missing_required`, `"<label>: <reason>"` for `invalid_value`. An `InvalidChoice` becomes `invalid_choice` with the exception's message.
- `None` for a non-required field means unset: it is skipped and no problem is reported. `None` or absence for a required field is `missing_required`.
- `coerce` returns only valid, set fields, in declaration order. It collects every problem; it never stops at the first.
- `JiraModel.__init__` now calls `coerce`. Any problems raise one `JiraError` containing all of them; otherwise the coerced values are stored. This replaces W3's unknown-kwarg check.
- `JiraModel.__setattr__`: for a schema field, call `coerce_field` and raise `JiraError` on a problem (assigning `None` to a required field is `missing_required`). Names starting with an underscore pass through. Any other unknown name raises `JiraError` with `unknown_field`.
- `validate.py` must not import `model.py` or `source.py`.

**Tests:** each problem code; several problems reported together; order of problems; coercion of enum values from raw strings; `None` handling for required and optional fields; the model raises on bad init and on bad assignment; assigning a valid value stores the coerced member.

**Out of scope:** remote checks.

## W5 — Payload encode and decode

**Read:** Design Doc, Payloads and preview. **Depends on:** W3 (W4 is not required).

**Goal:** convert values to Jira API dicts and back.

**Files:** `payload.py`, `fields.py` (add two members), `model.py` (edit), `tests/test_payload.py`.

```python
def to_payload(schema: JiraIssueSchema, values: Mapping[str, Any]) -> dict[str, Any]: ...        # {"fields": {...}}
def to_create_payload(schema: JiraIssueSchema, values: Mapping[str, Any], project_key: str) -> dict[str, Any]: ...
def from_payload(schema: JiraIssueSchema, payload: Mapping[str, Any]) -> dict[str, Any]: ...    # values dict
# JiraModel gains: to_payload(), to_create_payload(project_key), classmethod from_payload(payload)
```

**Rules**

- Add `PROJECT = ("project", "Project")` and `ISSUETYPE = ("issuetype", "Issue type")` to `JiraFieldId`. Models do not declare them.
- `to_payload` assumes values are already valid and does not validate. For each field in schema order that is set and not `None`: `payload["fields"][spec.id] = spec.codec.encode(value)`. Keys are `JiraFieldId` members.
- `to_create_payload` is `to_payload` plus `fields.project = {"key": project_key}` and `fields.issuetype = {"name": schema.issue_type}`. Keep it a separate function: the create envelope may change (see the open JSM decision in the Design Doc).
- `from_payload` decodes each ID in `payload["fields"]` that exists in `schema.by_id()` into its attribute name. Unknown IDs and `None` values are skipped. It returns a values dict.
- `JiraModel.from_payload(payload)` is `cls(**from_payload(cls.schema(), payload))`, so decoded values are validated.
- Never mutate inputs. `json.dumps(to_payload(...))` must succeed with no custom encoder.

**Tests:** payload for a sample model including enum, option, named and list fields; unset and `None` fields omitted; create payload adds project and issuetype; round trip `from_payload(to_payload(x))` equals `x`; unknown IDs ignored; `json.dumps` works; update payload has no project or issuetype.

**Out of scope:** HTTP, remote checks.

## W6 — Preview

**Read:** Design Doc, Payloads and preview. **Depends on:** W3.

**Goal:** turn values into rows a UI can render.

**Files:** `preview.py`, `model.py` (edit), `tests/test_preview.py`.

```python
@dataclass(frozen=True)
class PreviewRow:
    label: str
    text: str
    required: bool
    missing: bool

def to_preview(schema: JiraIssueSchema, values: Mapping[str, Any], *, include_missing_required: bool = True) -> list[PreviewRow]: ...
# JiraModel gains: to_preview(include_missing_required: bool = True)
```

**Rules**

- Rows follow schema declaration order. A set, non-`None` field gives `text = spec.codec.display(value)` and `missing = False`.
- A required field that is unset gives a row with `text = ""` and `missing = True` when `include_missing_required` is true, and no row otherwise.
- Optional unset fields produce no row.
- `label` is `spec.label`. The function returns rows, not a formatted string, and does no I/O.
- `preview.py` must not import `model.py` or `source.py`.

**Tests:** row order; display for enum, list, optional and datetime fields; missing required row; the flag turned off; label override from `JiraField(label=...)`.

**Out of scope:** rendering to text, HTML or Slack.

## W7 — Remote metadata check

**Read:** Design Doc, Remote metadata and drift checks. **Depends on:** W4, W5.

**Goal:** compare values with Jira's live configuration, offline-testable.

**Files:** `remote.py`, `model.py` (edit), `tests/fixtures/createmeta.json`, `tests/test_remote.py`.

```python
@dataclass(frozen=True)
class JiraFieldMeta:  id: str; required: bool; allowed_values: frozenset[str] | None
@dataclass(frozen=True)
class JiraMeta:       issue_type: str; fields: Mapping[str, JiraFieldMeta]

class JiraMetaProvider(Protocol):
    def meta(self, issue_type: str) -> JiraMeta: ...

class CachedMetaProvider:
    def __init__(self, inner: JiraMetaProvider, *, ttl_seconds: float = 300, clock: Callable[[], float] = time.monotonic) -> None: ...

def parse_createmeta(raw: Mapping[str, Any], issue_type: str) -> JiraMeta: ...
def check_remote(schema: JiraIssueSchema, values: Mapping[str, Any], meta: JiraMeta) -> list[Problem]: ...
# JiraModel gains: validate_against(meta: JiraMeta) -> list[Problem]
```

**Rules**

- `parse_createmeta` accepts both response shapes: `{"fields": [{"fieldId": ..., "required": ..., "allowedValues": [...]}]}` (a list) and `{"fields": {"<id>": {"required": ..., "allowedValues": [...]}}}` (a dict). An allowed value is the entry's `value`, else its `name`. A field with no `allowedValues` gets `None`.
- `check_remote` rules are in the Design Doc. To compare, encode the value with its codec. If the result is a dict with `value` or `name`, use that string; if it is a list, check each item; otherwise use `str(...)`.
- A field Jira marks required that is not declared in the schema yields `Problem(field=None, code="required_remote", ...)` naming the Jira field ID.
- `CachedMetaProvider` caches per issue type until the TTL expires, using the injected clock.

**Tests:** parse both shapes; `unavailable_remote`; `required_remote` for a declared and an undeclared field; `not_allowed_remote` for an enum value and for a list item; the happy path returns no problems; cache hit and expiry with a fake clock; `validate_against` on a model.

**Fixture:** write a small realistic `createmeta.json` by hand in the list shape (three or four fields including one select with `allowedValues`). Say in the test module's docstring that it is hand-written and should be replaced with a recorded response from the real instance.

**Out of scope:** HTTP.

## W8 — HTTP client

**Read:** Design Doc, Interfaces and Payloads and preview. **Depends on:** W5, W7.

**Goal:** an HTTP implementation of `JiraClient` and of `JiraMetaProvider`, plus `JiraModel.submit`. Use the HTTP library the repo already depends on (`requests` if there is none). This is the only workload that may touch the network layer.

**Files:** `client.py`, `model.py` (edit), `tests/test_client.py`.

```python
@dataclass(frozen=True)
class IssueRef:  key: str; id: str; url: str | None

class JiraApiError(Exception):
    status: int
    errors: Mapping[str, str]       # Jira's per-field "errors" object
    messages: tuple[str, ...]       # Jira's "errorMessages"

class JiraClient(Protocol):
    def create(self, payload: dict[str, Any]) -> IssueRef: ...
    def update(self, key: str, payload: dict[str, Any]) -> None: ...

class HttpJiraClient:
    def __init__(self, base_url: str, auth: tuple[str, str], *, session: Any | None = None, timeout: float = 30.0) -> None: ...
    def create(self, payload) -> IssueRef: ...     # POST {base_url}/rest/api/2/issue
    def update(self, key, payload) -> None: ...    # PUT  {base_url}/rest/api/2/issue/{key}

class HttpJiraMetaProvider:
    def __init__(self, base_url: str, auth: tuple[str, str], *, project_key: str, issue_type_ids: Mapping[str, str], session: Any | None = None, timeout: float = 30.0) -> None: ...
    def meta(self, issue_type: str) -> JiraMeta: ...   # GET create-metadata for the project and issue-type id, parsed with parse_createmeta

# JiraModel gains: submit(client, project_key, *, meta_provider: JiraMetaProvider | None = None) -> IssueRef
```

**Rules**

- Put every endpoint path in a constant at the top of the file. The create path and the create-metadata path (`/rest/api/2/issue/createmeta/{project}/issuetypes/{issue_type_id}`) are unverified; the Design Doc lists the open decisions, so they must be easy to change.
- A non-2xx response raises `JiraApiError` with the status and Jira's `errors` and `errorMessages` parsed from the JSON body when present. Never put credentials in an error message or a log line.
- `submit` order: if `meta_provider` is given, call `validate_against(meta_provider.meta(issue_type))` and raise `JiraError` on problems **before any create request**; then `client.create(self.to_create_payload(project_key))`.
- No retries. Tests use an injected fake session and never touch the network.

**Tests:** a successful create parses `IssueRef`; a 400 with `errors` maps to `JiraApiError`; auth and timeout are passed to the session; `update` sends `PUT`; metadata is parsed into `JiraMeta`; `submit` with failing metadata raises and makes no HTTP call; credentials never appear in error text.

**Notes:** if this is too large, split into W8a (`HttpJiraClient`, `IssueRef`, `JiraApiError`) and W8b (`HttpJiraMetaProvider` and `submit`).

**Out of scope:** retries, pagination, attachments, transitions.

## W9 — Exports, docs, example and contract tests

**Read:** the whole Design Doc. **Depends on:** W1 to W8.

**Goal:** a clean public API, a README that is tested, and the tests that guard the design.

**Files:** `__init__.py`, `README.md` (in the package), `tests/example_models.py`, `tests/test_readme.py`, `tests/test_contract.py`, `tests/test_architecture.py`.

**Rules**

- `__init__.py` re-exports the public API and defines `__all__`: `JiraFieldId`, `JiraField`, `JiraModel`, `JiraError`, `Problem`, `PreviewRow`, `JiraMeta`, `JiraFieldMeta`, `JiraMetaProvider`, `CachedMetaProvider`, `JiraClient`, `HttpJiraClient`, `HttpJiraMetaProvider`, `IssueRef`, `JiraApiError`, `FieldCodec`, and the helpers `option`, `named`, `user`, `list_of`.
- `tests/example_models.py` defines a `Bug` model that uses an enum, an option, a named field, a user, a list and a datetime. The README and the tests share it.
- `README.md` covers: what the package is for; defining a model (the full `Bug` example); required, labels and codecs; `to_payload` and `to_preview` examples; validation errors; the remote check and the contract test; how to add a field ID; and the gotchas (`None` means unset, no type checks beyond enums, literals and lists, and the open create-envelope decision).
- `test_readme.py` extracts the README's python code blocks and executes them in order, so the docs cannot rot.
- `test_contract.py` loads `tests/fixtures/createmeta.json`, parses it, and asserts that `check_remote` reports nothing for a valid `Bug` and the expected problems for an invalid one. It must fail when an enum member is missing from the fixture's allowed values.
- `test_architecture.py` parses `errors.py`, `fields.py`, `schema.py`, `codecs.py`, `validate.py`, `payload.py`, `preview.py` and `remote.py` with `ast` and asserts none of them imports `model.py` or `source.py`.

**Out of scope:** any behavior change in W0 to W8. If a test here exposes a bug, report it instead of patching it.

## Definition of done

A workload is finished when all of these hold. The final report lists files changed, tests run, assumptions made, and anything deferred.

- Every test in `tests/` passes with `pytest`, and none touches the network.
- The repo's linter and type checker are clean on the files the workload touched.
- Public names and signatures match this spec exactly.
- Core modules (`errors`, `fields`, `schema`, `codecs`, `validate`, `payload`, `preview`, `remote`) do not import `model.py` or `source.py`.
- No new dependency was added, except the HTTP library permitted in W8.
- No file outside the workload's **Files** list was changed.

## Final step — apply the real project name

The code uses the generic `Jira` prefix. After W9 passes, run the rename script once to switch to the real project's prefix. It renames identifiers only (prose such as "Jira API" is untouched), plus the `jirakit` package directory, and works in place.

```bash
./rename-prefix.sh <ProjectName> <repo path> --dry-run   # list what would change
./rename-prefix.sh <ProjectName> <repo path>             # apply
```

The script recognizes only the Jira-prefixed names allowed in Global conventions. If a workload introduced another one, add its suffix to `SUFFIXES` in the script first. Afterwards, run the full test suite.
